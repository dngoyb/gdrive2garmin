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
msg_ok "Configured fit2garmin"

msg_info "Setting up Cron Automation"
cat <<'EOF' >/opt/fit2garmin/sync.sh
#!/usr/bin/env bash
set -e

# Configuration defaults (change if your rclone remote or folder differs)
REMOTE="${RCLONE_REMOTE:-gdrive}"
REMOTE_FOLDER="${RCLONE_FOLDER:-fit_files}"
LOCAL_FOLDER="/opt/fit2garmin/fit_files"

# Check if rclone remote has been configured
if rclone listremotes 2>/dev/null | grep -q "^${REMOTE}:"; then
  rclone sync "${REMOTE}:${REMOTE_FOLDER}" "$LOCAL_FOLDER"
else
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Warning: rclone remote '${REMOTE}' not configured yet. Run 'rclone config'."
fi

# Run fit2garmin upload script
if [[ -f /opt/fit2garmin/fit2garmin.py ]]; then
  python3 /opt/fit2garmin/fit2garmin.py
elif [[ -f /opt/fit2garmin/upload_file_garmin.py ]]; then
  python3 /opt/fit2garmin/upload_file_garmin.py
fi
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
echo -e "${TAB}${GATEWAY} 1. Edit Garmin credentials in ${BL}/opt/fit2garmin/config.py${CL}:"
echo -e "${TAB}      Set ${GN}garmin_email${CL} and ${GN}garmin_password${CL}"
echo -e "${TAB}${GATEWAY} 2. Authenticate Google Drive via rclone:"
echo -e "${TAB}      Run ${BL}rclone config${CL} and name your remote ${GN}gdrive${CL}"
echo -e "${TAB}${GATEWAY} 3. Test synchronization anytime:"
echo -e "${TAB}      ${BL}/opt/fit2garmin/sync.sh${CL}"
echo -e "${TAB}${GATEWAY} 4. The automated cron job runs every 15 minutes."
echo -e "${TAB}      Logs: ${BL}/var/log/gdrive2garmin.log${CL}\n"
