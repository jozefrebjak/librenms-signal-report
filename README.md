# librenms-signal-report

[![shellcheck](https://github.com/jozefrebjak/librenms-signal-report/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/jozefrebjak/librenms-signal-report/actions/workflows/shellcheck.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: bash](https://img.shields.io/badge/shell-bash%203.2%2B-4eaa25.svg)](https://www.gnu.org/software/bash/)

Single-shell-script NOC morning report that pulls active alerts and down
devices from [LibreNMS](https://www.librenms.org/) and posts a Signal-friendly
summary to a group or contact via a self-hosted
[`signal-cli-rest-api`](https://github.com/bbernhard/signal-cli-rest-api).

Built to run from cron on a Linux box (Ubuntu/Debian/RHEL). Portable enough to
develop on macOS with the system `bash 3.2`.

## What it does

On each run the script:

1. Calls `GET /api/v0/alerts?state=<n>` and `GET /api/v0/devices?type=down`.
2. Pulls the full device list once to identify `disabled=1` / `ignore=1` nodes
   and filters them out — polling-disabled boxes never make it into the report.
3. Suppresses duplicate `Device Down [ICMP]` alerts for hosts already listed
   in the **DEVICES DOWN** section.
4. Checks the TLS certificate served by `LIBRENMS_URL` and warns once it is
   within `SSL_WARN_DAYS` (14) of expiry, escalating below `SSL_CRIT_DAYS` (7).
5. Renders a plain-text, Signal-mobile-friendly report (no code fences — Signal
   does not render triple-backtick blocks) with emoji section headers.
6. POSTs the message to `signal-cli-rest-api` `/v2/send`.

Example output (rendered in Signal):

```text
📡 NOC Alert Report
🕐 2026-05-17 08:00:01
📂 Project: WARP

🔴 Down: 2  ·  🚨 Alerts: 1  ·  🔐 SSL: 12d

🔴 DEVICES DOWN (2)
  • core-rtr-01 (icmp)
  • edge-sw-03 (snmp)

🚨 CRITICAL (1)
  • fw-01 → BGP Session Down (2026-05-17 07:42:11)

⚠️  SSL CERT EXPIRING
  • librenms.example.com expires in 12 days (2026-05-29)
  • Manual renewal required via ssl-manager
```

## Requirements

| Component | Notes |
| --- | --- |
| `bash` | 3.2+ (macOS system bash works; no `declare -A`, no `mapfile`) |
| `curl` | Any recent version |
| `jq` | 1.6+ |
| `openssl` | Only for the SSL expiry check (`SSL_CHECK=1`, the default) |
| LibreNMS | Reachable URL + API token with read access |
| signal-cli-rest-api | **Self-hosted** instance, sender already registered |

Install on Debian/Ubuntu:

```bash
sudo apt update && sudo apt install -y curl jq openssl
```

Install on RHEL/Rocky:

```bash
sudo dnf install -y curl jq openssl
```

### Hosting signal-cli-rest-api

This script does **not** ship a Signal stack — you need your own
`signal-cli-rest-api` instance with a registered sender number. Minimal Docker
setup:

```bash
docker run -d --name signal-api --restart=always \
  -p 8080:8080 \
  -v /opt/signal-cli-config:/home/.local/share/signal-cli \
  -e 'MODE=json-rpc' \
  bbernhard/signal-cli-rest-api:latest
```

Then register and verify your sender number per the
[upstream docs](https://github.com/bbernhard/signal-cli-rest-api#register-a-number).
Reverse-proxy it behind nginx/Caddy with HTTPS and basic-auth — those
credentials go into `SIGNAL_API_USER` / `SIGNAL_API_PASS`.

## Install

```bash
sudo install -d /opt/librenms-signal-report
sudo git clone https://github.com/jozefrebjak/librenms-signal-report.git /opt/librenms-signal-report
sudo cp /opt/librenms-signal-report/.env.example /opt/librenms-signal-report/.env
sudo chmod 600 /opt/librenms-signal-report/.env
sudo $EDITOR /opt/librenms-signal-report/.env
```

The script auto-discovers `.env` next to itself via `BASH_SOURCE` — no `cd`
required from cron. Override the path with `ENV_FILE=/elsewhere/.env`.

## Configuration

All settings live in `.env`. See [`.env.example`](.env.example) for the full
template.

| Variable | Required | Description |
| --- | :-: | --- |
| `LIBRENMS_URL` | ✓ | Base URL, e.g. `https://librenms.example.com` |
| `LIBRENMS_TOKEN` | ✓ | API token (User → API Access in LibreNMS) |
| `SIGNAL_API_URL` | ✓ | `signal-cli-rest-api` base URL |
| `SIGNAL_API_USER` | ✓ | HTTP basic-auth user |
| `SIGNAL_API_PASS` | ✓ | HTTP basic-auth password |
| `SIGNAL_SENDER` | ✓ | Registered phone number in E.164 (e.g. `+421900000000`) |
| `SIGNAL_RECIPIENT` | ✓ | Group ID (`group.<base64>`) or E.164 phone number |
| `PROJECT_GROUP` |   | Label in the report header — does **not** filter |
| `ALERT_STATE` |   | `0` recovered, `1` active (default), `2` acknowledged |
| `ALERT_SEVERITY` |   | `critical` / `warning` / `ok`; empty = all |
| `SSL_CHECK` |   | `1` check the LibreNMS certificate (default), `0` skip |
| `SSL_WARN_DAYS` |   | First warning threshold in days (default `14`) |
| `SSL_CRIT_DAYS` |   | Escalation threshold in days (default `7`) |
| `SSL_TIMEOUT` |   | TLS handshake timeout in seconds (default `10`) |
| `SSL_MANAGER_HINT` |   | Action line under the warning (default mentions `ssl-manager`) |

### SSL certificate expiry

The LibreNMS certificate is not renewed automatically — it has to be reissued
by hand through ssl-manager — so every run checks it and puts the result in the
same Signal message as the alerts:

| Days left | Report |
| --- | --- |
| more than `SSL_WARN_DAYS` (14) | nothing (does not break **All clear**) |
| `SSL_WARN_DAYS` … `SSL_CRIT_DAYS` | `⚠️  SSL CERT EXPIRING` + renewal hint |
| `SSL_CRIT_DAYS` (7) or less | `🚨 SSL CERT EXPIRING` + renewal hint |
| already past `notAfter` | `🚨 SSL CERT EXPIRED` + renewal hint |
| handshake failed / no `openssl` | `❓ SSL CERT CHECK FAILED` |

The check is skipped when `LIBRENMS_URL` is plain HTTP or `SSL_CHECK=0`. It
reads `notAfter` from the leaf certificate via
`openssl s_client -servername <host>` and needs `openssl` on the box (`timeout`
or `gtimeout` is used to bound the handshake when available). Because the
warning is repeated in every run below the threshold, a daily cron gives a
daily reminder from day 14 down to renewal.

Verify manually:

```bash
echo | openssl s_client -connect librenms.example.com:443 \
  -servername librenms.example.com 2>/dev/null | openssl x509 -noout -enddate
```

### Finding a group ID

```bash
curl -s -u "$SIGNAL_API_USER:$SIGNAL_API_PASS" \
  "$SIGNAL_API_URL/v1/groups/$SIGNAL_SENDER" | jq '.[] | {id, name}'
```

Use the `id` field (the `group.<base64>` string) as `SIGNAL_RECIPIENT`. Direct
phone-number recipients only work if the recipient is already in the bot's
contact list.

## Usage

Manual run:

```bash
/opt/librenms-signal-report/noc-report.sh
```

Dry-run (print report, skip Signal send):

```bash
DRY_RUN=1 /opt/librenms-signal-report/noc-report.sh
```

Override config file on the fly:

```bash
ENV_FILE=/etc/librenms-signal-report/staging.env /opt/librenms-signal-report/noc-report.sh
```

## Cron deployment

Daily 08:00 morning report, log to a writable file:

```cron
0 8 * * * /opt/librenms-signal-report/noc-report.sh >> /var/log/noc-report.log 2>&1
```

Make sure the log target is writable by the cron user:

```bash
sudo install -o "$USER" -m 0644 /dev/null /var/log/noc-report.log
```

If `/bin/sh: ...: not found` shows up in cron output, it's almost always one
of:

- **CRLF line endings** — `sed -i 's/\r$//' /opt/librenms-signal-report/noc-report.sh`
- **Missing exec bit** — `chmod +x /opt/librenms-signal-report/noc-report.sh`
- **Wrong path** — verify with `realpath /opt/librenms-signal-report/noc-report.sh`

## How alert deduplication works

LibreNMS keeps an alert at `state=1` until the device sends a recovery — but
if you disable polling on a host (`disabled=1`), no recovery is ever produced
and the alert sticks forever. To keep the morning report honest:

1. The script fetches `/api/v0/devices` once per run and builds a set of
   `device_id`s where `disabled=1 OR ignore=1`.
2. Both the down list and the alert list filter those IDs out.
3. For devices that are legitimately down, the matching `Device Down [ICMP]`
   alert is suppressed in the **CRITICAL** section — it's already shown under
   **DEVICES DOWN**. Non-`Device Down` alerts (e.g. high CPU) for the same
   host still appear.

## Compatibility

| Platform | Tested |
| --- | --- |
| Ubuntu 22.04 / 24.04 (bash 5.x) | ✓ |
| Debian 12 (bash 5.x) | ✓ |
| macOS 14+ system bash 3.2 | ✓ |

No `declare -A`, no `mapfile`, portable `mktemp` template — the script runs on
the macOS system bash without needing Homebrew bash.

## Development

```bash
shellcheck noc-report.sh
DRY_RUN=1 ./noc-report.sh
```

CI runs `shellcheck -o all` on every push and pull request — see
[`.github/workflows/shellcheck.yml`](.github/workflows/shellcheck.yml).

## License

[MIT](LICENSE) © 2026 jozefrebjak
