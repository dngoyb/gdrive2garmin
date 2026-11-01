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

# Verify downloaded file against expected SHA256 checksum
# Usage: verify_checksum <file> <expected_sha256>
verify_checksum() {
  local file="$1"
  local expected="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local actual
  actual=$(sha256sum "$file" | awk '{print $1}')
  [[ "$actual" == "$expected" ]]
}

# Download with checksum verification
# Usage: safe_download <url> <output_file> <expected_sha256>
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

  # Expected SHA256 checksums for release files (update these when releasing new versions)
  # These should be updated via CI/CD when publishing releases
  local FIT2GARMIN_SHA256="PLACEHOLDER_UPDATE_ON_RELEASE"
  local INSTALL_SH_SHA256="PLACEHOLDER_UPDATE_ON_RELEASE"
  local SETUP_SH_SHA256="PLACEHOLDER_UPDATE_ON_RELEASE"

  # Update sync engine
  if safe_download "https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/fit2garmin_modern.py" \
      /opt/fit2garmin/fit2garmin.py "$FIT2GARMIN_SHA256"; then
    chmod +x /opt/fit2garmin/fit2garmin.py
    msg_ok "Updated fit2garmin.py"
  else
    msg_warn "Failed to verify/update fit2garmin.py (checksum mismatch or download failed)"
  fi

  # Update sync.sh by downloading install script and extracting sync.sh
  if [[ -f /opt/fit2garmin/sync.sh ]]; then
    local tmp_install="/tmp/install_update.sh"
    if safe_download "https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/gdrive2garmin-install.sh" \
        "$tmp_install" "$INSTALL_SH_SHA256"; then
      # Extract and deploy the updated sync.sh from the install script
      sed -n '/^cat <<'"'"'EOF'"'"' >\/opt\/fit2garmin\/sync.sh/,/^EOF$/p' "$tmp_install" | head -n -1 | tail -n +2 > /opt/fit2garmin/sync.sh.new 2>/dev/null || true
      if [[ -s /opt/fit2garmin/sync.sh.new ]]; then
        mv /opt/fit2garmin/sync.sh.new /opt/fit2garmin/sync.sh
        chmod +x /opt/fit2garmin/sync.sh
        msg_ok "Updated sync.sh"
      fi

      # Update logrotate config
      sed -n '/^cat <<'"'"'EOF'"'"' >\/etc\/logrotate.d\/gdrive2garmin/,/^EOF$/p' "$tmp_install" | head -n -1 | tail -n +2 > /etc/logrotate.d/gdrive2garmin 2>/dev/null || true
      msg_ok "Updated logrotate config"
    else
      msg_warn "Failed to verify/update install script (checksum mismatch or download failed)"
    fi
    rm -f "$tmp_install"
  fi

  # Update setup wizard
  if safe_download "https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/setup.sh" \
      /opt/fit2garmin/setup.sh "$SETUP_SH_SHA256"; then
    chmod +x /opt/fit2garmin/setup.sh
    ln -sf /opt/fit2garmin/setup.sh /usr/local/bin/gdrive2garmin-setup
    msg_ok "Updated setup.sh"
  else
    msg_warn "Failed to verify/update setup.sh (checksum mismatch or download failed)"
  fi

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
echo -e "  • Alert webhook configuration (ntfy.sh, Discord, Slack, etc.)"
echo -e "  • Live test synchronization & cron validation"
echo -e "  (Logs: /var/log/gdrive2garmin.log [rotated daily, 14 days] | Cron: Active hours every 30m)"
