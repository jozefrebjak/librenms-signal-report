#!/bin/bash
# LibreNMS NOC alert report
# Fetches active alerts, checks the LibreNMS TLS certificate expiry and prints
# a Signal-friendly summary.
# PROJECT_GROUP is shown in the header only — it does not filter alerts.
#
# Usage:
#   ./noc-report.sh                  # use .env in script directory
#   ENV_FILE=/path/to/.env ./noc-report.sh
#   PROJECT_GROUP=WARP ./noc-report.sh   # only changes the header label
#   SSL_CHECK=0 ./noc-report.sh          # skip the certificate check

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/.env}"

if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a
fi

# Required — LibreNMS
: "${LIBRENMS_URL:?LIBRENMS_URL is not set (check .env)}"
: "${LIBRENMS_TOKEN:?LIBRENMS_TOKEN is not set (check .env)}"

# Required — Signal API
: "${SIGNAL_API_URL:?SIGNAL_API_URL is not set (check .env)}"
: "${SIGNAL_API_USER:?SIGNAL_API_USER is not set (check .env)}"
: "${SIGNAL_API_PASS:?SIGNAL_API_PASS is not set (check .env)}"
: "${SIGNAL_SENDER:?SIGNAL_SENDER is not set (check .env)}"
: "${SIGNAL_RECIPIENT:?SIGNAL_RECIPIENT is not set (check .env)}"

# Optional with defaults
PROJECT_GROUP="${PROJECT_GROUP:-}"
ALERT_STATE="${ALERT_STATE:-1}"
ALERT_SEVERITY="${ALERT_SEVERITY:-}"

# Optional — TLS certificate check for LIBRENMS_URL
SSL_CHECK="${SSL_CHECK:-1}"
SSL_WARN_DAYS="${SSL_WARN_DAYS:-14}"
SSL_CRIT_DAYS="${SSL_CRIT_DAYS:-7}"
SSL_TIMEOUT="${SSL_TIMEOUT:-10}"
SSL_MANAGER_HINT="${SSL_MANAGER_HINT:-Manual renewal required via ssl-manager}"

# Strip trailing slash from URLs
LIBRENMS_URL="${LIBRENMS_URL%/}"
SIGNAL_API_URL="${SIGNAL_API_URL%/}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

api_get() {
    local path="$1"
    curl -sS --fail-with-body \
        -H "X-Auth-Token: ${LIBRENMS_TOKEN}" \
        "${LIBRENMS_URL}/api/v0/${path}"
}

# Resolve device ID -> hostname (memoized via temp file for bash 3.2 compatibility)
HOSTNAME_CACHE_FILE=$(mktemp "${TMPDIR:-/tmp}/noc-report-hostname-cache.XXXXXX")
trap 'rm -f "$HOSTNAME_CACHE_FILE"' EXIT

device_hostname() {
    local device_id="$1"
    local cached
    cached=$(grep -m1 "^${device_id}	" "${HOSTNAME_CACHE_FILE}" 2>/dev/null | cut -f2-)
    if [[ -n "${cached}" ]]; then
        echo "${cached}"
        return
    fi
    local hostname
    hostname=$(api_get "devices/${device_id}" | jq -r '.devices[0].sysName // .devices[0].hostname // "unknown"')
    printf '%s\t%s\n' "${device_id}" "${hostname}" >> "${HOSTNAME_CACHE_FILE}"
    echo "${hostname}"
}

# Map LibreNMS severity string to display label (with emoji)
severity_label() {
    case "$1" in
        critical) echo "🚨 CRITICAL" ;;
        warning)  echo "⚠️  WARNING" ;;
        ok)       echo "✅ OK" ;;
        *)        echo "❓ UNKNOWN" ;;
    esac
}

# Split "https://host:port/path" into "host port" (port defaults to 443)
url_host_port() {
    local url="$1"
    local hostport="${url#*://}"
    hostport="${hostport%%/*}"
    hostport="${hostport##*@}"

    local host port
    case "${hostport}" in
        \[*\]:*)                                     # [2001:db8::1]:8443
            host="${hostport%]:*}"
            port="${hostport##*]:}"
            ;;
        \[*\])                                       # [2001:db8::1]
            host="${hostport%]}"
            port="443"
            ;;
        *:*)                                         # host:8443
            host="${hostport%:*}"
            port="${hostport##*:}"
            ;;
        *)                                           # host
            host="${hostport}"
            port="443"
            ;;
    esac
    printf '%s %s\n' "${host#\[}" "${port}"
}

# Read the notAfter field of the certificate served by host:port
cert_not_after() {
    local host="$1" port="$2"
    local timeout_cmd=()
    if command -v timeout >/dev/null 2>&1; then
        timeout_cmd=(timeout "${SSL_TIMEOUT}")
    elif command -v gtimeout >/dev/null 2>&1; then
        timeout_cmd=(gtimeout "${SSL_TIMEOUT}")
    fi

    echo \
        | ${timeout_cmd[@]+"${timeout_cmd[@]}"} \
            openssl s_client -connect "${host}:${port}" -servername "${host}" 2>/dev/null \
        | openssl x509 -noout -enddate 2>/dev/null \
        | cut -d= -f2 || true
}

# Print "<days_left> <expiry_epoch>" for host:port, or nothing when the
# certificate is unreachable/unparsable. days_left is negative once expired.
cert_days_left() {
    local host="$1" port="$2"
    local not_after expiry_epoch now_epoch

    not_after=$(cert_not_after "${host}" "${port}")
    [[ -n "${not_after}" ]] || return 0

    # Collapse the space-padded day ("Aug  6" -> "Aug 6") for BSD strptime
    not_after="${not_after//  / }"

    expiry_epoch=$(date -d "${not_after}" '+%s' 2>/dev/null) \
        || expiry_epoch=$(date -j -f '%b %d %H:%M:%S %Y %Z' "${not_after}" '+%s' 2>/dev/null) \
        || return 0

    now_epoch=$(date '+%s')
    printf '%s %s\n' "$(( (expiry_epoch - now_epoch) / 86400 ))" "${expiry_epoch}"
}

# Format an epoch as YYYY-MM-DD (GNU date, then BSD date)
epoch_to_date() {
    date -d "@$1" '+%Y-%m-%d' 2>/dev/null \
        || date -r "$1" '+%Y-%m-%d' 2>/dev/null \
        || echo "?"
}

# Send a plain-text message via signal-cli-rest-api (POST /v2/send)
signal_send() {
    local message="$1"
    local payload
    payload=$(jq -nc \
        --arg message "${message}" \
        --arg number "${SIGNAL_SENDER}" \
        --arg recipient "${SIGNAL_RECIPIENT}" \
        '{message: $message, number: $number, recipients: [$recipient]}')

    echo "Sending report to Signal recipient ${SIGNAL_RECIPIENT} ..." >&2
    curl -sS --fail-with-body \
        -u "${SIGNAL_API_USER}:${SIGNAL_API_PASS}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        "${SIGNAL_API_URL}/v2/send" >&2
    echo >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "Fetching alerts from ${LIBRENMS_URL} ..." >&2

# Build alerts URL
alerts_url="alerts?state=${ALERT_STATE}"
if [[ -n "${ALERT_SEVERITY}" ]]; then
    alerts_url="${alerts_url}&severity=${ALERT_SEVERITY}"
fi

alerts_json=$(api_get "${alerts_url}")

echo "Fetching down devices ..." >&2
devices_down_json=$(api_get "devices?type=down")

echo "Fetching device list (to filter disabled/ignored) ..." >&2
all_devices_json=$(api_get "devices")
excluded_ids=$(echo "${all_devices_json}" | jq -c '[.devices[] | select(.disabled == 1 or .ignore == 1) | .device_id]')

# Drop devices that have polling or alerting disabled
devices_down=$(echo "${devices_down_json}" | jq -c --argjson excl "${excluded_ids}" '
    .devices[] | select((.device_id | IN($excl[])) | not)
')
down_count=$(echo "${devices_down}" | grep -c . || true)

# Active devices that are currently down (used to suppress duplicate "Device Down" alerts)
down_device_ids=$(echo "${devices_down}" | jq -sc 'map(.device_id)')

# Alerts: drop disabled/ignored devices, and drop "Device Down" alerts for devices listed above
alerts=$(echo "${alerts_json}" | jq -c --argjson excl "${excluded_ids}" --argjson down "${down_device_ids}" '
    .alerts[]
    | select((.device_id | IN($excl[])) | not)
    | select(
        ((.device_id | IN($down[])) and ((.name // "") | test("Device Down"))) | not
      )
')
total=$(echo "${alerts}" | grep -c . || true)

# ---------------------------------------------------------------------------
# TLS certificate of LIBRENMS_URL — warn below SSL_WARN_DAYS, escalate below
# SSL_CRIT_DAYS. Certificates are renewed by hand through ssl-manager, so this
# has to land in Signal early enough for someone to act on it.
# ---------------------------------------------------------------------------

ssl_status=""       # ok | warning | critical | expired | error
ssl_host=""
ssl_days=""
ssl_expiry_date=""
ssl_error=""

if [[ "${SSL_CHECK}" == "1" && "${LIBRENMS_URL}" == https://* ]]; then
    ssl_hostport=$(url_host_port "${LIBRENMS_URL}")
    read -r ssl_host ssl_port <<<"${ssl_hostport}"
    echo "Checking SSL certificate for ${ssl_host}:${ssl_port} ..." >&2

    if ! command -v openssl >/dev/null 2>&1; then
        ssl_status="error"
        ssl_error="openssl not installed"
    else
        ssl_probe=$(cert_days_left "${ssl_host}" "${ssl_port}")
        if [[ -n "${ssl_probe}" ]]; then
            read -r ssl_days ssl_expiry_epoch <<<"${ssl_probe}"
            ssl_expiry_date=$(epoch_to_date "${ssl_expiry_epoch}")
            if [[ "${ssl_days}" -lt 0 ]]; then
                ssl_status="expired"
            elif [[ "${ssl_days}" -le "${SSL_CRIT_DAYS}" ]]; then
                ssl_status="critical"
            elif [[ "${ssl_days}" -le "${SSL_WARN_DAYS}" ]]; then
                ssl_status="warning"
            else
                ssl_status="ok"
            fi
        else
            ssl_status="error"
            ssl_error="certificate could not be read"
        fi
    fi
fi

# Short SSL marker for the summary line (empty unless action is needed)
ssl_summary_suffix() {
    case "${ssl_status}" in
        warning|critical) echo "  ·  🔐 SSL: ${ssl_days}d" ;;
        expired)          echo "  ·  🔐 SSL: expired" ;;
        *)                : ;;
    esac
}

# Full SSL block for the report body (empty unless action is needed)
ssl_section() {
    case "${ssl_status}" in
        expired)
            echo ""
            echo "🚨 SSL CERT EXPIRED"
            echo "  • ${ssl_host} expired on ${ssl_expiry_date} ($(( -ssl_days )) days ago)"
            echo "  • ${SSL_MANAGER_HINT}"
            ;;
        critical)
            echo ""
            echo "🚨 SSL CERT EXPIRING"
            echo "  • ${ssl_host} expires in ${ssl_days} days (${ssl_expiry_date})"
            echo "  • ${SSL_MANAGER_HINT}"
            ;;
        warning)
            echo ""
            echo "⚠️  SSL CERT EXPIRING"
            echo "  • ${ssl_host} expires in ${ssl_days} days (${ssl_expiry_date})"
            echo "  • ${SSL_MANAGER_HINT}"
            ;;
        error)
            echo ""
            echo "❓ SSL CERT CHECK FAILED"
            echo "  • ${ssl_host}: ${ssl_error}"
            ;;
        *)
            : ;;
    esac
}

# ---------------------------------------------------------------------------
# Format report (Signal-friendly: header + monospace code blocks)
# ---------------------------------------------------------------------------

timestamp=$(date '+%Y-%m-%d %H:%M:%S')
project_label="${PROJECT_GROUP:-ALL}"
ssl_suffix=$(ssl_summary_suffix)

report=$(
    echo "📡 NOC Alert Report"
    echo "🕐 ${timestamp}"
    echo "📂 Project: ${project_label}"
    echo ""
    echo "🔴 Down: ${down_count}  ·  🚨 Alerts: ${total}${ssl_suffix}"

    if [[ "${down_count}" -gt 0 ]]; then
        echo ""
        echo "🔴 DEVICES DOWN (${down_count})"
        while IFS= read -r device; do
            [[ -z "${device}" ]] && continue
            name=$(echo "${device}" | jq -r '.sysName // .hostname // "unknown"')
            reason=$(echo "${device}" | jq -r '.status_reason // "?"')
            echo "  • ${name} (${reason})"
        done <<<"${devices_down}"
    fi

    if [[ "${total}" -gt 0 ]]; then
        for severity in critical warning ok; do
            label=$(severity_label "${severity}")
            matching=$(echo "${alerts}" | jq -c --arg sev "${severity}" 'select(.severity == $sev)' || true)
            count=$(echo "${matching}" | grep -c . || true)
            [[ "${count}" -eq 0 ]] && continue

            echo ""
            echo "${label} (${count})"
            while IFS= read -r alert; do
                [[ -z "${alert}" ]] && continue
                device_id=$(echo "${alert}" | jq -r '.device_id')
                rule=$(echo "${alert}" | jq -r '.name // .rule // "Unknown rule"')
                when=$(echo "${alert}" | jq -r '.timestamp // "?"')
                hostname=$(device_hostname "${device_id}")
                echo "  • ${hostname} → ${rule} (${when})"
            done <<<"${matching}"
        done
    fi

    ssl_section

    if [[ "${total}" -eq 0 && "${down_count}" -eq 0 && ( -z "${ssl_status}" || "${ssl_status}" == "ok" ) ]]; then
        echo ""
        echo "✅ All clear — no active alerts, no devices down."
    fi
)

echo "${report}"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "(DRY_RUN=1 — skipping Signal send)" >&2
else
    signal_send "${report}"
fi
