#!/bin/bash
# Creates or migrates the ERPNext site and applies the stack's environment.
# Runs on every `docker compose up` and is safe to repeat:
# - Bench config (database, Redis, Socket.IO) in common_site_config.json.
# - No site yet: `bench new-site` with ERPNext, then the setup wizard
#   (company, country, currency, fiscal year, first user), run once.
# - New image (ERPNEXT_VERSION changed): `bench migrate` (also across major
#   versions, Frappe's upgrade path). An image older than the site is refused.
# - On every run: site URL (host_name) and SMTP from the environment.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=common.sh
. "$(dirname "$0")/common.sh"
cd "${BENCH}"

if [ "$(echo "${SMTP_SECURE:-}" | tr '[:upper:]' '[:lower:]')" = ssl ]; then
    echo "WARNING: SMTP_SECURE=ssl is not supported by the mail server from the" \
        "site config (STARTTLS only): use SMTP_SECURE=tls with port 587, or add an" \
        "Email Account in ERPNext." >&2
fi

echo "==> Bench configuration"
ls -1 apps > sites/apps.txt
json_set "${GLOBAL_CONFIG}" db_host "${DB_HOST}"
json_set "${GLOBAL_CONFIG}" db_port "${DB_PORT}" --json
json_set "${GLOBAL_CONFIG}" redis_cache "redis://redis-cache:6379"
json_set "${GLOBAL_CONFIG}" redis_queue "redis://redis-queue:6379"
json_set "${GLOBAL_CONFIG}" redis_socketio "redis://redis-queue:6379"
json_set "${GLOBAL_CONFIG}" socketio_port 9000 --json
json_set "${GLOBAL_CONFIG}" default_site "${ERPNEXT_SITE}"

wait-for-it -q -t 120 "${DB_HOST}:${DB_PORT}"
wait-for-it -q -t 120 redis-cache:6379
wait-for-it -q -t 120 redis-queue:6379

image_version="$(env/bin/python -c 'import erpnext; print(erpnext.__version__)')"
db="$(site_db)"
installed=""
if [ -n "${db}" ]; then
    # Separate assignment: with `set -e`, a failing query aborts setup here.
    installed="$(sql "SELECT app_version FROM \`${db}\`.\`tabInstalled Application\` WHERE app_name = 'erpnext'" 2>/dev/null || true)"
fi

if [ -z "${installed}" ]; then
    echo "==> Creating site ${ERPNEXT_SITE} (ERPNext ${image_version})"
    # --force: a previous attempt may have left the site half created.
    bench new-site "${ERPNEXT_SITE}" --force \
        --mariadb-user-host-login-scope='%' \
        --db-root-username=root --db-root-password="${DB_ROOT_PASSWORD}" \
        --admin-password="${ERPNEXT_ADMIN_PASSWORD}" \
        --install-app=erpnext
    db="$(site_db)"
elif [ "$(jq -r '.docker_stack_image // empty' "${SITE_CONFIG}")" != "${ERPNEXT_VERSION}" ]; then
    oldest="$(printf '%s\n%s\n' "${installed}" "${image_version}" | sort -V | head -1)"
    if [ "${installed}" != "${image_version}" ] && [ "${oldest}" = "${image_version}" ]; then
        echo "The site is ERPNext ${installed}, the image ${image_version}: downgrades are not supported." >&2
        exit 1
    fi
    echo "==> Migrating site ${ERPNEXT_SITE}: ERPNext ${installed} -> ${image_version}"
    # The cache keeps the previous version's module list (`app_modules`):
    # migrating from v15 to v16 fails on a removed module (frappe.social).
    # It's only a cache (the queue is another Redis): empty it first.
    env/bin/python -c 'import redis; redis.Redis.from_url("redis://redis-cache:6379").flushall()'
    bench --site "${ERPNEXT_SITE}" migrate
fi

# new-site doesn't create the key for stored passwords: Frappe generates it on
# first use, and two processes doing that at once (each caches the site config
# for 60 s) leave passwords encrypted with a lost key. Create it before any
# other service starts.
if [ -z "$(jq -r '.encryption_key // empty' "${SITE_CONFIG}")" ]; then
    json_set "${SITE_CONFIG}" encryption_key \
        "$(env/bin/python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"
fi

setup_complete="$(sql "SELECT is_setup_complete FROM \`${db}\`.\`tabInstalled Application\` WHERE app_name = 'erpnext'")"
if [ "${setup_complete}" != 1 ]; then
    echo "==> Setup wizard (${ERPNEXT_COMPANY_NAME}, ${ERPNEXT_COUNTRY}, ${ERPNEXT_CURRENCY})"
    language="$(sql "SELECT language_name FROM \`${db}\`.tabLanguage WHERE name = '${ERPNEXT_LANG}'")"
    year="$(date +%Y)"
    args="$(jq -cn \
        --arg language "${language:-English}" \
        --arg country "${ERPNEXT_COUNTRY}" \
        --arg timezone "${ERPNEXT_TIMEZONE}" \
        --arg currency "${ERPNEXT_CURRENCY}" \
        --arg full_name "${ERPNEXT_ADMIN_NAME}" \
        --arg email "${ERPNEXT_ADMIN_EMAIL}" \
        --arg password "${ERPNEXT_ADMIN_PASSWORD}" \
        --arg company_name "${ERPNEXT_COMPANY_NAME}" \
        --arg company_abbr "${ERPNEXT_COMPANY_ABBR}" \
        --arg chart_of_accounts "${ERPNEXT_CHART_OF_ACCOUNTS}" \
        --arg fy_start_date "${year}-${ERPNEXT_FISCAL_YEAR_START}" \
        --arg fy_end_date "$(date -d "$((year + 1))-${ERPNEXT_FISCAL_YEAR_START} -1 day" +%F)" \
        '{args: {language: $language, lang: $language, country: $country,
          timezone: $timezone, currency: $currency, full_name: $full_name,
          email: $email, password: $password, company_name: $company_name,
          company_abbr: $company_abbr, chart_of_accounts: $chart_of_accounts,
          fy_start_date: $fy_start_date, fy_end_date: $fy_end_date,
          setup_demo: 0, enable_telemetry: 0}}')"
    bench --site "${ERPNEXT_SITE}" execute \
        frappe.desk.page.setup_wizard.setup_wizard.setup_complete --kwargs "${args}"
    # The wizard can log a failed step and still mark the setup as complete.
    setup_complete="$(sql "SELECT is_setup_complete FROM \`${db}\`.\`tabInstalled Application\` WHERE app_name = 'erpnext'")"
    company="$(sql "SELECT COUNT(*) FROM \`${db}\`.tabCompany")"
    if [ "${setup_complete}" != 1 ] || [ "${company}" = 0 ]; then
        echo "The setup wizard failed (see the output above)." >&2
        exit 1
    fi
    # Scheduled jobs created by new-site carry timestamps in Frappe's default
    # time zone (Asia/Kolkata); after the wizard's time zone, jobs behind it
    # (e.g. the email queue) wouldn't run for hours. Start them from now.
    now="$(bench --site "${ERPNEXT_SITE}" execute frappe.utils.now | tail -1 | tr -d '"')"
    sql "UPDATE \`${db}\`.\`tabScheduled Job Type\` SET last_execution = '${now}' WHERE last_execution IS NULL"
    # Amounts in each currency's own number format (CLP: no decimals; by
    # default Frappe uses the system format, 2 decimals). Saved as a document
    # so Frappe updates its defaults.
    bench --site "${ERPNEXT_SITE}" execute frappe.client.set_value --args \
        '["System Settings", "System Settings", "use_number_format_from_currency", 1]' > /dev/null
fi

echo "==> Applying environment (URL, mail)"
url_host="$(echo "${ERPNEXT_URL}" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')"
if [ "${url_host}" != "${ERPNEXT_HOST}" ]; then
    echo "WARNING: ERPNEXT_HOST (${ERPNEXT_HOST}) is not the host of ERPNEXT_URL" \
        "(${url_host}): PDFs may fail to load their styles and images." >&2
fi
json_set "${SITE_CONFIG}" host_name "${ERPNEXT_URL}"
# Default outgoing mail server, used unless an Email Account is the default.
# Frappe turns STARTTLS on whenever a login is set.
use_tls=0
[ "$(echo "${SMTP_SECURE:-}" | tr '[:upper:]' '[:lower:]')" = tls ] && use_tls=1
json_set "${SITE_CONFIG}" mail_server "${SMTP_HOST:-}"
json_set "${SITE_CONFIG}" mail_port "${SMTP_HOST:+${SMTP_PORT}}" --json
json_set "${SITE_CONFIG}" use_tls "${SMTP_HOST:+${use_tls}}" --json
json_set "${SITE_CONFIG}" mail_login "${SMTP_USER:-}"
json_set "${SITE_CONFIG}" mail_password "${SMTP_PASSWORD:-}"
json_set "${SITE_CONFIG}" auto_email_id "${SMTP_FROM:-}"
json_set "${SITE_CONFIG}" email_sender_name "${SMTP_FROM_NAME:-}"
if [ -n "${SMTP_HOST:-}" ] && [ -z "${SMTP_USER:-}" ]; then
    json_set "${SITE_CONFIG}" disable_mail_smtp_authentication 1 --json
else
    json_set "${SITE_CONFIG}" disable_mail_smtp_authentication ""
fi
# Marker of the image the site was migrated to: written last.
json_set "${SITE_CONFIG}" docker_stack_image "${ERPNEXT_VERSION}"

echo "==> Done: ERPNext ${image_version}, site ${ERPNEXT_SITE}"
echo "    URL:   ${ERPNEXT_URL}"
echo "    Login: ${ERPNEXT_ADMIN_EMAIL} (or Administrator)"
