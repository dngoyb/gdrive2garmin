#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Community Contributor
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Jacopo1891/fit2garmin

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Verify downloaded file against expected SHA256 checksum
verify_checksum() {
  local file="$1"
  local expected="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ "$actual" == "$expected" ]
}

# Download with checksum verification
safe_download() {
  local url="$1"
  local output="$2"
  local expected_sha256="$3"

  curl -fsSL "$url" -o "$output" 2>/dev/null || return 1
  if ! verify_checksum "$output" "$expected_sha256"; then
    echo "ERROR: Checksum verification failed for $url" >&2
    rm -f "$output"
    return 1
  fi
  return 0
}

# Expected SHA256 checksums for release files (update these when releasing new versions)
# These should be updated via CI/CD when publishing releases
FIT2GARMIN_SHA256="PLACEHOLDER_UPDATE_ON_RELEASE"
INSTALL_SH_SHA256="PLACEHOLDER_UPDATE_ON_RELEASE"
SETUP_SH_SHA256="PLACEHOLDER_UPDATE_ON_RELEASE"

msg_info "Installing Dependencies"
$STD apt-get install -y \
  python3 \
  python3-pip \
  python3-dev \
  libffi-dev \
  rclone \
  git \
  cron \
  curl \
  logrotate \
  jq
systemctl enable -q --now cron
msg_ok "Installed Dependencies"

msg_info "Setting up fit2garmin"
$STD git clone https://github.com/Jacopo1891/fit2garmin.git /opt/fit2garmin
# Debian 12 uses PEP 668 externally managed environment - install modern garminconnect + curl_cffi
$STD pip3 install --break-system-packages garminconnect curl_cffi || $STD pip3 install garminconnect curl_cffi
# Deploy modern sync engine (replaces deprecated garth with curl_cffi TLS impersonation)
if safe_download "https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/fit2garmin_modern.py" \
    /opt/fit2garmin/fit2garmin.py "$FIT2GARMIN_SHA256"; then
  chmod +x /opt/fit2garmin/fit2garmin.py
  msg_ok "Deployed fit2garmin.py (verified)"
else
  echo -e "${YW}[!] Failed to verify fit2garmin.py, using fallback${CL}"
  if [[ ! -s /opt/fit2garmin/fit2garmin.py && -f "$(dirname "${BASH_SOURCE[0]}")/fit2garmin_modern.py" ]]; then
    cp "$(dirname "${BASH_SOURCE[0]}")/fit2garmin_modern.py" /opt/fit2garmin/fit2garmin.py
  fi
  chmod +x /opt/fit2garmin/fit2garmin.py
fi
msg_ok "Setup fit2garmin"

msg_info "Configuring fit2garmin"
mkdir -p /opt/fit2garmin/fit_files
cp /opt/fit2garmin/config.example.py /opt/fit2garmin/config.py
sed -i 's|garmin_email = .*|garmin_email = ""|' /opt/fit2garmin/config.py
sed -i 's|garmin_password = .*|garmin_password = ""|' /opt/fit2garmin/config.py
sed -i 's|folder_path = .*|folder_path = "/opt/fit2garmin/fit_files"|' /opt/fit2garmin/config.py
echo 'token_store_path = "~/.garminconnect"' >> /opt/fit2garmin/config.py
chmod 600 /opt/fit2garmin/config.py

cat <<'EOF' >/opt/fit2garmin/sync.env
RCLONE_REMOTE="gdrive"
RCLONE_FOLDER="fit_files"
CLEANUP_NON_FIT="true"
FIT_RETENTION_DAYS="5"
# Alert webhook URL (optional): ntfy.sh, Pushover, Discord, Slack, etc.
# Must be HTTPS URL. Example: https://ntfy.sh/mytopic or Discord webhook URL
# ALERT_WEBHOOK_URL=""
# ALERT_ON_SUCCESS="false"
EOF
chmod 600 /opt/fit2garmin/sync.env
msg_ok "Configured fit2garmin"

msg_info "Setting up Log Rotation"
cat <<'EOF' >/etc/logrotate.d/gdrive2garmin
/var/log/gdrive2garmin.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 644 root root
    sharedscripts
    postrotate
        systemctl reload cron > /dev/null 2>&1 || true
    endscript
}
EOF
msg_ok "Configured Log Rotation"

msg_info "Setting up Setup Wizard"
curl -fsSL "https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/setup.sh" -o /opt/fit2garmin/setup.sh 2>/dev/null || true
if [[ ! -s /opt/fit2garmin/setup.sh ]]; then
  # Fallback to copy if installed locally or offline
  if [[ -f "$(dirname "${BASH_SOURCE[0]}")/setup.sh" ]]; then
    cp "$(dirname "${BASH_SOURCE[0]}")/setup.sh" /opt/fit2garmin/setup.sh
  fi
fi
chmod +x /opt/fit2garmin/setup.sh
ln -sf /opt/fit2garmin/setup.sh /usr/local/bin/gdrive2garmin-setup
msg_ok "Setup Setup Wizard"

msg_info "Setting up Cron Automation"
cat <<'EOF' >/opt/fit2garmin/sync.sh
#!/usr/bin/env bash
set -e

# Load custom configuration if present
if [[ -f /opt/fit2garmin/sync.env ]]; then
  # shellcheck source=/dev/null
  source /opt/fit2garmin/sync.env
fi

REMOTE="${RCLONE_REMOTE:-gdrive}"
REMOTE_FOLDER="${RCLONE_FOLDER:-fit_files}"
LOCAL_FOLDER="/opt/fit2garmin/fit_files"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"
ALERT_ON_SUCCESS="${ALERT_ON_SUCCESS:-false}"

# Validate webhook URL - must be HTTPS and not point to localhost/internal IPs
validate_webhook_url() {
  local url="$1"
  # Must start with https://
  [[ "$url" =~ ^https:// ]] || return 1
  # Block localhost, private IPs, metadata endpoints
  [[ "$url" =~ (^|://)(localhost|127\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|169\.254\.|169\.254\.169\.254) ]] && return 1
  return 0
}

# Sanitize log output for alerts - remove potential secrets
sanitize_for_alert() {
  local input="$1"
  # Remove lines that look like they contain passwords, tokens, keys
  echo "$input" | sed -E \
    -e 's/(password|passwd|pwd|token|secret|key|auth)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\\1=***REDACTED***/gi' \
    -e 's/(garmin_email|garmin_password|access_token|refresh_token|client_secret)[[:space:]]*[:=][[:space:]]*[^[:space:]]+/\\1=***REDACTED***/gi' \
    -e 's/Bearer[[:space:]]+[^[:space:]]+/Bearer ***REDACTED***/gi'
}

# Alert function
send_alert() {
  local status="$1"
  local message="$2"
  local details="${3:-}"

  if [[ -z "$ALERT_WEBHOOK_URL" ]]; then
    return 0
  fi

  # Validate webhook URL to prevent SSRF
  if ! validate_webhook_url "$ALERT_WEBHOOK_URL"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: Invalid or blocked webhook URL (must be HTTPS, no localhost/private IPs)" >&2
    return 0
  fi

  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  local hostname
  hostname=$(hostname)

  # Sanitize message and details to prevent data leakage
  message=$(sanitize_for_alert "$message")
  details=$(sanitize_for_alert "$details")

  # Build JSON payload safely using jq (prevents injection)
  local payload
  payload=$(jq -n \
    --arg topic "gdrive2garmin" \
    --arg title "gdrive2garmin: ${status}" \
    --arg message "$message" \
    --arg timestamp "$timestamp" \
    --arg hostname "$hostname" \
    --arg details "$details" \
    '{topic: $topic, title: $title, message: $message, timestamp: $timestamp, hostname: $hostname, details: $details}')

  curl -fsS -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
}

# Trap errors for alerting - sanitize log tail to prevent secret exposure
trap 'send_alert "FAILED" "Sync failed with error on line $LINENO" "$(tail -20 /var/log/gdrive2garmin.log 2>/dev/null | sanitize_for_alert | tr '\''\n'\'' '\'' '\'' )"; exit 1' ERR

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting gdrive2garmin sync..."

# Check if rclone remote has been configured
if rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing from Google Drive (${REMOTE}:${REMOTE_FOLDER}) to ${LOCAL_FOLDER}..."
  rclone sync "${REMOTE}:${REMOTE_FOLDER}" "$LOCAL_FOLDER" --include "*.fit" --include "*.FIT"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Google Drive sync completed."
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: rclone remote '${REMOTE}' not configured yet. Run 'gdrive2garmin-setup'."
  send_alert "CONFIG_ERROR" "rclone remote '${REMOTE}' not configured" "Run gdrive2garmin-setup inside the container"
  exit 1
fi

# Run fit2garmin upload script
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Uploading FIT files to Garmin Connect..."
cd /opt/fit2garmin
UPLOAD_OUTPUT=""
UPLOAD_EXIT=0
if [[ -f /opt/fit2garmin/fit2garmin.py ]]; then
  UPLOAD_OUTPUT=$(python3 /opt/fit2garmin/fit2garmin.py 2>&1) || UPLOAD_EXIT=$?
elif [[ -f /opt/fit2garmin/upload_file_garmin.py ]]; then
  UPLOAD_OUTPUT=$(python3 /opt/fit2garmin/upload_file_garmin.py 2>&1) || UPLOAD_EXIT=$?
fi
echo "$UPLOAD_OUTPUT"

# Check upload result
if [[ $UPLOAD_EXIT -ne 0 ]]; then
  send_alert "UPLOAD_FAILED" "Garmin upload script exited with code $UPLOAD_EXIT" "$UPLOAD_OUTPUT"
  exit $UPLOAD_EXIT
fi

# Extract summary from output
UPLOADED=$(echo "$UPLOAD_OUTPUT" | grep -oE '([0-9]+) uploaded' | head -1 | awk '{print $1}')
DUPLICATES=$(echo "$UPLOAD_OUTPUT" | grep -oE '([0-9]+) duplicates' | head -1 | awk '{print $1}')
ERRORS=$(echo "$UPLOAD_OUTPUT" | grep -oE '([0-9]+) errors' | head -1 | awk '{print $1}')
UPLOADED=${UPLOADED:-0}
DUPLICATES=${DUPLICATES:-0}
ERRORS=${ERRORS:-0}

# Cleanup Google Drive: remove redundant formats (.gpx, .kml, .tcx, .csv)
if [[ "${CLEANUP_NON_FIT:-true}" == "true" ]]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaning redundant non-FIT files from Google Drive..."
  rclone delete "${REMOTE}:${REMOTE_FOLDER}" \
    --include "*.gpx" --include "*.GPX" \
    --include "*.kml" --include "*.KML" \
    --include "*.tcx" --include "*.TCX" \
    --include "*.csv" --include "*.CSV" || true
fi

# Retention policy: purge .fit files older than FIT_RETENTION_DAYS (default: 5 days)
if [[ -n "${FIT_RETENTION_DAYS:-}" && "${FIT_RETENTION_DAYS}" -gt 0 ]] 2>/dev/null; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Purging FIT files older than ${FIT_RETENTION_DAYS} days from Google Drive..."
  rclone delete "${REMOTE}:${REMOTE_FOLDER}" \
    --min-age "${FIT_RETENTION_DAYS}d" \
    --include "*.fit" --include "*.FIT" || true
fi

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Finished gdrive2garmin sync."

# Send success alert if enabled
if [[ "$ALERT_ON_SUCCESS" == "true" && -n "$ALERT_WEBHOOK_URL" ]]; then
  send_alert "SUCCESS" "Sync completed: ${UPLOADED} uploaded, ${DUPLICATES} duplicates, ${ERRORS} errors" "Upload: ${UPLOADED}, Duplicates: ${DUPLICATES}, Errors: ${ERRORS}"
fi
EOF
chmod +x /opt/fit2garmin/sync.sh

cat <<'EOF' >/etc/cron.d/gdrive2garmin
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Active hours: Morning (06:00-11:30), Midday (14:00-15:30), Evening (17:00-19:30) every 30 minutes
0,30 6-11,14-15,17-19 * * * root /opt/fit2garmin/sync.sh >> /var/log/gdrive2garmin.log 2>&1
EOF
chmod 644 /etc/cron.d/gdrive2garmin
msg_ok "Setup Cron Automation"

motd_ssh
customize
cleanup_lxc

echo -e "\n${TAB}${YW}IMPORTANT: Setup Required Inside Container${CL}"
echo -e "${TAB}${GATEWAY} 1. Enter the container: ${BL}pct enter <CTID>${CL}"
echo -e "${TAB}${GATEWAY} 2. Launch the interactive setup wizard:"
echo -e "${TAB}      ${GN}gdrive2garmin-setup${CL}"
echo -e "${TAB}${GATEWAY} 3. The wizard will configure Garmin, rclone (Google Drive), and test sync."
echo -e "${TAB}${GATEWAY} 4. Automated cron runs every 30 minutes during active hours (06:00-11:30, 14:00-15:30, 17:00-19:30)."
echo -e "${TAB}      Logs: ${BL}/var/log/gdrive2garmin.log${CL} (rotated daily, kept 14 days)"
echo -e "${TAB}      Alerts: Configure ALERT_WEBHOOK_URL in /opt/fit2garmin/sync.env${CL}\n"

