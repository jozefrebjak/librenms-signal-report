#!/bin/bash
# LibreNMS NOC alert report
# Fetches active alerts and prints a Signal-friendly summary.
# PROJECT_GROUP is shown in the header only — it does not filter alerts.
#
# Usage:
#   ./noc-report.sh                  # use .env in script directory
#   ENV_FILE=/path/to/.env ./noc-report.sh
#   PROJECT_GROUP=WARP ./noc-report.sh   # only changes the header label

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
# Format report (Signal-friendly: header + monospace code blocks)
# ---------------------------------------------------------------------------

timestamp=$(date '+%Y-%m-%d %H:%M:%S')
project_label="${PROJECT_GROUP:-ALL}"

report=$(
    echo "📡 NOC Alert Report"
    echo "🕐 ${timestamp}"
    echo "📂 Project: ${project_label}"
    echo ""
    echo "🔴 Down: ${down_count}  ·  🚨 Alerts: ${total}"

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

    if [[ "${total}" -eq 0 && "${down_count}" -eq 0 ]]; then
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
