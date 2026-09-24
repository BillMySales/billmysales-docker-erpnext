#!/bin/bash
# Backups of the ERPNext site: database, public and private files, and the
# site config (it holds the encryption key of stored passwords).
#
#   backup.sh            # loop: back up now, then every BACKUP_INTERVAL_HOURS
#   backup.sh now        # one backup
#   backup.sh list       # list backups
#   backup.sh restore <timestamp>   # restore database, files and encryption key
#   backup.sh health     # healthcheck: last backup is recent enough
#
# Each backup is a directory /backups/<timestamp>/ with bench's files
# (*-database.sql.gz, *-files.tar, *-private-files.tar, *-site_config_backup.json),
# deleted after BACKUP_KEEP_DAYS days. Runs as root only to own /backups;
# bench runs as the image's `frappe` user.
set -euo pipefail
# Backups contain password hashes and customer data: owner-only files.
umask 077

# shellcheck source-path=SCRIPTDIR source=common.sh
. "$(dirname "$0")/common.sh"
BACKUP_DIR=/backups

as_frappe() { runuser -u frappe -- "$@"; }

backup() {
    local ts tmp
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    echo "==> Backup ${ts}"
    tmp="${BACKUP_DIR}/.${ts}"
    mkdir -p "${tmp}"
    chown frappe:frappe "${tmp}"
    (cd "${BENCH}" && as_frappe bench --site "${ERPNEXT_SITE}" backup --with-files --backup-path "${tmp}")
    chown -R root:root "${tmp}"
    chmod -R go-rwx "${tmp}"
    mv "${tmp}" "${BACKUP_DIR}/${ts}"
    find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*' \
        -mtime +"${BACKUP_KEEP_DAYS}" -exec rm -rf {} +
    ls -lh "${BACKUP_DIR}/${ts}"
}

restore() {
    local ts="${1:?Usage: backup.sh restore <timestamp> (see: backup.sh list)}"
    local dir="${BACKUP_DIR}/${ts}" work db files private conf key
    [ -d "${dir}" ] || { echo "Backup ${ts} not found" >&2; exit 1; }
    db="$(find "${dir}" -name '*-database.sql.gz' | head -1)"
    files="$(find "${dir}" -name '*-files.tar' ! -name '*-private-files.tar' | head -1)"
    private="$(find "${dir}" -name '*-private-files.tar' | head -1)"
    conf="$(find "${dir}" -name '*-site_config_backup.json' | head -1)"
    [ -n "${db}" ] || { echo "No database dump in ${dir}" >&2; exit 1; }

    # bench runs as frappe: give it a readable copy.
    work="$(mktemp -d)"
    cp "${dir}"/* "${work}/"
    chown -R frappe:frappe "${work}"
    set -- --db-root-username=root --db-root-password="${DB_ROOT_PASSWORD}" --force
    [ -n "${files}" ] && set -- "$@" --with-public-files="${work}/$(basename "${files}")"
    [ -n "${private}" ] && set -- "$@" --with-private-files="${work}/$(basename "${private}")"

    echo "==> Restoring ${ts}"
    cd "${BENCH}"
    as_frappe bench --site "${ERPNEXT_SITE}" restore "${work}/$(basename "${db}")" "$@"
    # Stored passwords (e.g. email accounts) need the backup's encryption key.
    if [ -n "${conf}" ]; then
        key="$(jq -r '.encryption_key // empty' "${conf}")"
        if [ -n "${key}" ]; then
            json_set "${SITE_CONFIG}" encryption_key "${key}"
            chown frappe:frappe "${SITE_CONFIG}"
        fi
    fi
    echo "==> Migrating (the backup may come from an older version)"
    # Cached data may belong to the database that was just replaced.
    env/bin/python -c 'import redis; redis.Redis.from_url("redis://redis-cache:6379").flushall()'
    as_frappe bench --site "${ERPNEXT_SITE}" migrate
    as_frappe bench --site "${ERPNEXT_SITE}" clear-cache
    rm -rf "${work}"
    echo "==> Restored ${ts}"
}

mkdir -p "${BACKUP_DIR}"
case "${1:-loop}" in
    now) backup ;;
    list)
        find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*' -exec basename {} \; | sort
        ;;
    restore) restore "${2:-}" ;;
    health)
        [ -n "$(find "${BACKUP_DIR}" -mindepth 1 -maxdepth 1 -type d -name '2*' \
            -mmin -$(( BACKUP_INTERVAL_HOURS * 60 + 60 )) 2>/dev/null)" ]
        ;;
    loop)
        while :; do
            backup || echo "Backup failed" >&2
            sleep $(( BACKUP_INTERVAL_HOURS * 3600 ))
        done
        ;;
    *) echo "Usage: backup.sh [now|list|restore <timestamp>|health|loop]" >&2; exit 2 ;;
esac
