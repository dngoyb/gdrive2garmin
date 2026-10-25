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

msg_info "Installing Dependencies"
$STD apt-get install -y \
  python3 \
  python3-pip \
  rclone \
  git \
  cron \
  curl
systemctl enable -q --now cron
msg_ok "Installed Dependencies"

msg_info "Setting up fit2garmin"
$STD git clone https://github.com/Jacopo1891/fit2garmin.git /opt/fit2garmin
# Debian 12 uses PEP 668 externally managed environment
$STD pip3 install --break-system-packages garth || $STD pip3 install garth
if [[ -f /opt/fit2garmin/upload_file_garmin.py && ! -f /opt/fit2garmin/fit2garmin.py ]]; then
  ln -s /opt/fit2garmin/upload_file_garmin.py /opt/fit2garmin/fit2garmin.py
fi
msg_ok "Setup fit2garmin"

msg_info "Configuring fit2garmin"
mkdir -p /opt/fit2garmin/fit_files
cp /opt/fit2garmin/config.example.py /opt/fit2garmin/config.py
sed -i 's|garmin_email = .*|garmin_email = ""|' /opt/fit2garmin/config.py
sed -i 's|garmin_password = .*|garmin_password = ""|' /opt/fit2garmin/config.py
sed -i 's|folder_path = .*|folder_path = "/opt/fit2garmin/fit_files"|' /opt/fit2garmin/config.py
chmod 600 /opt/fit2garmin/config.py

cat <<'EOF' >/opt/fit2garmin/sync.env
RCLONE_REMOTE="gdrive"
RCLONE_FOLDER="fit_files"
EOF
chmod 600 /opt/fit2garmin/sync.env
msg_ok "Configured fit2garmin"

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

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting gdrive2garmin sync..."

# Check if rclone remote has been configured
if rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:"; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Syncing from Google Drive (${REMOTE}:${REMOTE_FOLDER}) to ${LOCAL_FOLDER}..."
  rclone sync "${REMOTE}:${REMOTE_FOLDER}" "$LOCAL_FOLDER" --include "*.fit" --include "*.FIT"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Google Drive sync completed."
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: rclone remote '${REMOTE}' not configured yet. Run 'gdrive2garmin-setup'."
  exit 1
fi

# Run fit2garmin upload script
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Uploading FIT files to Garmin Connect..."
cd /opt/fit2garmin
if [[ -f /opt/fit2garmin/fit2garmin.py ]]; then
  python3 /opt/fit2garmin/fit2garmin.py
elif [[ -f /opt/fit2garmin/upload_file_garmin.py ]]; then
  python3 /opt/fit2garmin/upload_file_garmin.py
fi
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Finished gdrive2garmin sync."
EOF
chmod +x /opt/fit2garmin/sync.sh

cat <<'EOF' >/etc/cron.d/gdrive2garmin
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

*/15 * * * * root /opt/fit2garmin/sync.sh >> /var/log/gdrive2garmin.log 2>&1
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
echo -e "${TAB}${GATEWAY} 4. Automated cron runs every 15 minutes."
echo -e "${TAB}      Logs: ${BL}/var/log/gdrive2garmin.log${CL}\n"
