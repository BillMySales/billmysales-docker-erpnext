#!/bin/bash
# shellcheck disable=SC2034 # variables used by the scripts that source this file
# Helpers shared by setup.sh and backup.sh (sourced). Run in the ERPNext image,
# from the bench directory.

BENCH=/home/frappe/frappe-bench
SITES="${BENCH}/sites"
GLOBAL_CONFIG="${SITES}/common_site_config.json"
SITE_CONFIG="${SITES}/${ERPNEXT_SITE}/site_config.json"

# SQL as the database root user (password through the environment, not argv).
sql() {
    MYSQL_PWD="${DB_ROOT_PASSWORD}" mariadb --host="${DB_HOST}" --port="${DB_PORT}" \
        --user=root --batch --skip-column-names -e "$1"
}

# Name of the site's database ("" if the site doesn't exist yet).
site_db() {
    if [ -f "${SITE_CONFIG}" ]; then
        jq -r '.db_name // empty' "${SITE_CONFIG}"
    fi
}

# Sets a key of a JSON config file, only when it changes; an empty value removes
# the key. Values are strings unless `--json` is given (numbers, booleans).
# Usage: json_set <file> <key> <value> [--json]
json_set() {
    local file="$1" key="$2" value="$3" type="${4:-}" current wanted tmp
    [ -f "${file}" ] || echo '{}' > "${file}"
    current="$(jq -c --arg k "${key}" '.[$k] // empty' "${file}")"
    if [ -z "${value}" ]; then
        wanted=""
    elif [ "${type}" = --json ]; then
        wanted="$(jq -cn --argjson v "${value}" '$v')"
    else
        wanted="$(jq -cn --arg v "${value}" '$v')"
    fi
    [ "${current}" = "${wanted}" ] && return 0
    tmp="$(mktemp "${file}.XXXXXX")"
    if [ -z "${wanted}" ]; then
        jq --arg k "${key}" 'del(.[$k])' "${file}" > "${tmp}"
    else
        jq --arg k "${key}" --argjson v "${wanted}" '.[$k] = $v' "${file}" > "${tmp}"
    fi
    chmod --reference="${file}" "${tmp}"
    mv "${tmp}" "${file}"
    echo "    ${key} updated"
}
