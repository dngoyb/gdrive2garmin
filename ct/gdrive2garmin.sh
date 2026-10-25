#!/usr/bin/env bash
_CS_DEFAULT_URL="https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main"
_cs_boot="${COMMUNITY_SCRIPTS_CORE_DIR:-$(dirname "${BASH_SOURCE[0]}")/../../core}/core/build.func"
source "$_cs_boot" 2>/dev/null || source <(curl -fsSL "${COMMUNITY_SCRIPTS_CORE_URL:-https://raw.githubusercontent.com/community-scripts/core/main}/core/build.func") || source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Community Contributor
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://github.com/Jacopo1891/fit2garmin

APP="gdrive2garmin"
var_tags="${var_tags:-fitness;sync;garmin}"
var_cpu="${var_cpu:-1}"
var_ram="${var_ram:-512}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -d /opt/fit2garmin ]]; then
    msg_error "No ${APP} Installation Found!"
    exit 1
  fi

  msg_info "Updating fit2garmin"
  cd /opt/fit2garmin
  git pull
  $STD pip3 install --upgrade --break-system-packages garminconnect curl_cffi
  curl -fsSL "https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/fit2garmin_modern.py" -o /opt/fit2garmin/fit2garmin.py 2>/dev/null || true
  chmod +x /opt/fit2garmin/fit2garmin.py
  msg_ok "Updated fit2garmin"
  msg_ok "Updated successfully!"
  exit
}

start
build_container
description

msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} LXC container has been successfully created!${CL}"
echo -e "${INFO}${YW}To complete setup, run the interactive setup wizard inside the container:${CL}"
echo -e "  ${BL}pct enter <CTID>${CL} (or open container console in Proxmox)"
echo -e "  ${GN}gdrive2garmin-setup${CL}"
echo -e ""
echo -e "${INFO}The wizard handles:"
echo -e "  • Garmin Connect credentials & authentication (with 2FA/MFA support)"
echo -e "  • Google Drive rclone configuration & folder selection"
echo -e "  • Live test synchronization & cron validation"
echo -e "  (Logs: /var/log/gdrive2garmin.log | Cron: Every 15 minutes)"

