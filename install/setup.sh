#!/usr/bin/env bash
# ==============================================================================
# gdrive2garmin - Interactive Setup Wizard
# ==============================================================================
set -euo pipefail

# If stdin is not a terminal (e.g. when piped via curl | bash), redirect from /dev/tty
if [ ! -t 0 ] && [ -e /dev/tty ]; then
  exec < /dev/tty
fi

# ANSI color codes
RD="\033[01;31m"
GN="\033[01;32m"
YW="\033[01;33m"
BL="\033[01;34m"
CY="\033[01;36m"
BOLD="\033[1m"
CL="\033[m"

INSTALL_DIR="/opt/fit2garmin"
CONFIG_FILE="${INSTALL_DIR}/config.py"
ENV_FILE="${INSTALL_DIR}/sync.env"
GARTH_DIR="/root/.garth"

clear 2>/dev/null || true
cat << "EOF"
   ____ ____       _           ____   ____                            _       
  / ___|  _ \ _ __(_)_   _____|___ \ / ___| __ _ _ __ _ __ ___  _ __ (_)_ __  
 | |  _| | | | '__| \ \ / / _ \ __) | |  _ / _` | '__| '_ ` _ \| '_ \| | '_ \ 
 | |_| | |_| | |  | |\ V /  __// __/| |_| | (_| | |  | | | | | | | | | | | | |
  \____|____/|_|  |_| \_/ \___|_____|\____|\__,_|_|  |_| |_| |_|_| |_|_|_| |_|
EOF
echo -e "${BOLD}================================================================${CL}"
echo -e "${CY}         gdrive2garmin Interactive Configuration Wizard         ${CL}"
echo -e "${BOLD}================================================================${CL}\n"

# Verify root privileges
if [[ $EUID -ne 0 ]]; then
  echo -e "${RD}[!] Error: This setup script must be run as root (or inside the container with root).${CL}"
  exit 1
fi

# Verify / create installation directory
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/fit_files" "$GARTH_DIR"
chmod 700 "$GARTH_DIR"

# Ensure garth is installed
if ! python3 -c "import garth" 2>/dev/null; then
  echo -e "${CY}Installing required Python dependency (garth)...${CL}"
  pip3 install --break-system-packages garth 2>/dev/null || pip3 install garth
fi

# Persist script in /opt/fit2garmin and symlink to PATH if not already there
if [[ ! -f "${INSTALL_DIR}/setup.sh" ]] || [[ "${BASH_SOURCE[0]:-}" != "${INSTALL_DIR}/setup.sh" ]]; then
  if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    cp "${BASH_SOURCE[0]}" "${INSTALL_DIR}/setup.sh" 2>/dev/null || true
  else
    curl -fsSL https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/setup.sh -o "${INSTALL_DIR}/setup.sh" 2>/dev/null || true
  fi
  chmod +x "${INSTALL_DIR}/setup.sh" 2>/dev/null || true
  ln -sf "${INSTALL_DIR}/setup.sh" /usr/local/bin/gdrive2garmin-setup 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# STEP 1: Garmin Connect Configuration
# ------------------------------------------------------------------------------
echo -e "${BOLD}${BL}▶ STEP 1: Garmin Connect Credentials${CL}"
echo -e "Enter your Garmin Connect account credentials to sync your activity/health data.\n"

CURRENT_EMAIL=""
if [[ -f "$CONFIG_FILE" ]]; then
  CURRENT_EMAIL=$(python3 -c "
try:
    import sys
    sys.path.insert(0, '${INSTALL_DIR}')
    import config
    print(getattr(config, 'garmin_email', ''))
except Exception:
    pass
" 2>/dev/null || true)
fi

PROMPT_EMAIL="Garmin Email"
if [[ -n "$CURRENT_EMAIL" ]]; then
  PROMPT_EMAIL="Garmin Email [current: ${CURRENT_EMAIL}]"
fi

read -r -p "$(echo -e "${YW}${PROMPT_EMAIL}: ${CL}")" GARMIN_EMAIL
if [[ -z "$GARMIN_EMAIL" && -n "$CURRENT_EMAIL" ]]; then
  GARMIN_EMAIL="$CURRENT_EMAIL"
fi

while [[ -z "$GARMIN_EMAIL" ]]; do
  echo -e "${RD}Email cannot be empty.${CL}"
  read -r -p "$(echo -e "${YW}Garmin Email: ${CL}")" GARMIN_EMAIL
done

read -r -s -p "$(echo -e "${YW}Garmin Password: ${CL}")" GARMIN_PASSWORD
echo ""

while [[ -z "$GARMIN_PASSWORD" ]]; do
  echo -e "${RD}Password cannot be empty.${CL}"
  read -r -s -p "$(echo -e "${YW}Garmin Password: ${CL}")" GARMIN_PASSWORD
  echo ""
done

echo -e "\n${CY}Updating ${CONFIG_FILE}...${CL}"
python3 - <<PYEOF
import re

config_path = "${CONFIG_FILE}"
email = """${GARMIN_EMAIL}"""
password = """${GARMIN_PASSWORD}"""

try:
    with open(config_path, "r") as f:
        content = f.read()
except FileNotFoundError:
    content = '''debug = True
garmin_email = ""
garmin_password = ""
folder_path = "/opt/fit2garmin/fit_files"
session_file_path = "~/.garth"
file_name_template = "{prefix} {date} {source}.fit"
file_name_config = {
    "prefix": "Huawei Health",
    "source": "Smart Scale"
}
'''

content = re.sub(r'garmin_email\s*=\s*.*', f'garmin_email = {repr(email)}', content)
content = re.sub(r'garmin_password\s*=\s*.*', f'garmin_password = {repr(password)}', content)
content = re.sub(r'folder_path\s*=\s*.*', 'folder_path = "/opt/fit2garmin/fit_files"', content)

with open(config_path, "w") as f:
    f.write(content)
PYEOF

chmod 600 "$CONFIG_FILE"
echo -e "${GN}[✓] Garmin credentials saved securely.${CL}"

# Authenticate with Garmin using Garth
echo -e "\n${CY}Authenticating with Garmin Connect...${CL}"
echo -e "${BL}(Note: If your Garmin account has Two-Factor Authentication (2FA/MFA) enabled,${CL}"
echo -e "${BL} Garmin will send a 6-digit code. Enter it below if prompted.)${CL}\n"

GARTH_AUTH_SUCCESS=0
python3 - <<PYEOF || GARTH_AUTH_SUCCESS=1
import sys
import os
import garth

email = """${GARMIN_EMAIL}"""
password = """${GARMIN_PASSWORD}"""
session_dir = os.path.expanduser("~/.garth")

try:
    garth.login(email, password)
    garth.save(session_dir)
    username = getattr(garth.client, 'username', 'Unknown')
    print(f"\033[01;32m[✓] Successfully authenticated as Garmin user: {username}\033[m")
    print(f"\033[01;32m[✓] Session tokens saved to: {session_dir}\033[m")
except Exception as e:
    print(f"\033[01;31m[!] Garmin authentication failed: {e}\033[m", file=sys.stderr)
    sys.exit(1)
PYEOF

if [[ $GARTH_AUTH_SUCCESS -ne 0 ]]; then
  echo -e "\n${YW}[!] Authentication failed. Please check credentials and re-run setup.${CL}"
else
  chmod 600 "$GARTH_DIR"/*.json 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
# STEP 2: Google Drive Configuration (rclone)
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${BL}▶ STEP 2: Google Drive Configuration (rclone)${CL}"
echo -e "Configure rclone to synchronize your .fit files from Google Drive.\n"

RCLONE_REMOTE_NAME="gdrive"
RCLONE_FOLDER_NAME="fit_files"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  RCLONE_REMOTE_NAME="${RCLONE_REMOTE:-gdrive}"
  RCLONE_FOLDER_NAME="${RCLONE_FOLDER:-fit_files}"
fi

REMOTE_EXISTS=0
if rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE_NAME}:"; then
  REMOTE_EXISTS=1
fi

if [[ $REMOTE_EXISTS -eq 1 ]]; then
  echo -e "${GN}[✓] rclone remote '${RCLONE_REMOTE_NAME}:' is already configured.${CL}"
  read -r -p "$(echo -e "${YW}Do you want to re-authenticate or reconfigure it? (y/N): ${CL}")" RECONFIG_RCLONE
  RECONFIG_RCLONE="${RECONFIG_RCLONE:-n}"
else
  RECONFIG_RCLONE="y"
fi

if [[ "$RECONFIG_RCLONE" =~ ^[Yy]$ ]]; then
  echo -e "\n${BOLD}Google Drive Authorization (Headless Setup):${CL}"
  echo -e "Because this LXC container has no web browser, Google OAuth authentication"
  echo -e "must be authorized from a device with a browser (your PC or Mac).\n"
  echo -e "Choose your configuration method:"
  echo -e "  ${BOLD}1)${CL} ${GN}Paste OAuth Token${CL} (Fastest - recommended)"
  echo -e "  ${BOLD}2)${CL} ${CY}Interactive rclone wizard${CL} (Standard 'rclone config' CLI)"
  echo -e "  ${BOLD}3)${CL} Skip for now"
  read -r -p "$(echo -e "${YW}Select option [1-3] (default: 1): ${CL}")" RCLONE_OPT
  RCLONE_OPT="${RCLONE_OPT:-1}"

  case "$RCLONE_OPT" in
    1)
      echo -e "\n${CY}--- Instructions to generate OAuth Token ---${CL}"
      echo -e "1. On your desktop/laptop (with rclone installed), open a terminal or command prompt."
      echo -e "2. Run this command: ${BOLD}${GN}rclone authorize \"drive\"${CL}"
      echo -e "3. A web browser will open. Sign into Google and click 'Allow'."
      echo -e "4. Copy the JSON token outputted in your local terminal."
      echo -e "   (It looks like: {\"access_token\":\"ya29...\",\"token_type\":\"Bearer\",...})"
      echo -e "5. Paste the entire JSON block below and press Enter:\n"
      read -r -p "$(echo -e "${YW}OAuth Token JSON: ${CL}")" RCLONE_TOKEN

      if [[ -n "$RCLONE_TOKEN" ]]; then
        echo -e "${CY}Creating rclone remote '${RCLONE_REMOTE_NAME}'...${CL}"
        if rclone config create "$RCLONE_REMOTE_NAME" drive token "$RCLONE_TOKEN" scope drive 2>/dev/null; then
          echo -e "${GN}[✓] Google Drive remote '${RCLONE_REMOTE_NAME}' created successfully!${CL}"
        else
          echo -e "${RD}[!] Failed to create remote with provided token. You can try option 2.${CL}"
        fi
      else
        echo -e "${YW}[!] No token entered. Skipping.${CL}"
      fi
      ;;
    2)
      echo -e "\n${CY}Launching interactive 'rclone config'...${CL}"
      echo -e "${BL}Recommended answers during prompts:${CL}"
      echo -e " • New remote: ${GN}n${CL}"
      echo -e " • Name: ${GN}${RCLONE_REMOTE_NAME}${CL}"
      echo -e " • Storage: ${GN}drive${CL} (Google Drive)"
      echo -e " • Client ID / Secret: Leave blank (press Enter)"
      echo -e " • Scope: ${GN}1${CL} (Full access)"
      echo -e " • Use web browser automatically: ${GN}n${CL} (Headless machine)"
      read -r -p "Press Enter to start rclone config..."
      rclone config
      ;;
    *)
      echo -e "${YW}Skipping rclone remote configuration.${CL}"
      ;;
  esac
fi

# Configure Google Drive folder
echo -e "\n${BOLD}Google Drive Source Folder:${CL}"
echo -e "Specify the folder in Google Drive where your exported .fit files are stored."
read -r -p "$(echo -e "${YW}Google Drive folder [default: ${RCLONE_FOLDER_NAME}]: ${CL}")" INPUT_FOLDER
if [[ -n "$INPUT_FOLDER" ]]; then
  RCLONE_FOLDER_NAME="$INPUT_FOLDER"
fi

cat <<EOF > "$ENV_FILE"
RCLONE_REMOTE="${RCLONE_REMOTE_NAME}"
RCLONE_FOLDER="${RCLONE_FOLDER_NAME}"
EOF
chmod 600 "$ENV_FILE"
echo -e "${GN}[✓] Sync settings saved to ${ENV_FILE}${CL}"

# Test Google Drive connection
echo -e "\n${CY}Testing connection to ${RCLONE_REMOTE_NAME}:${RCLONE_FOLDER_NAME}...${CL}"
if rclone lsf "${RCLONE_REMOTE_NAME}:${RCLONE_FOLDER_NAME}" --max-depth 1 >/tmp/rclone_test.txt 2>&1; then
  FILE_COUNT=$(grep -c '\.fit$' /tmp/rclone_test.txt 2>/dev/null || true)
  TOTAL_FILES=$(wc -l < /tmp/rclone_test.txt 2>/dev/null || true)
  echo -e "${GN}[✓] Connected to Google Drive successfully!${CL}"
  echo -e "    Found ${GN}${FILE_COUNT}${CL} .fit file(s) (${TOTAL_FILES} items total) in '${RCLONE_FOLDER_NAME}'."
  rm -f /tmp/rclone_test.txt
else
  echo -e "${YW}[!] Note: Could not list files in '${RCLONE_REMOTE_NAME}:${RCLONE_FOLDER_NAME}'.${CL}"
  echo -e "    Ensure the folder exists in your Google Drive and the remote is authorized."
fi

# ------------------------------------------------------------------------------
# STEP 3: Test Synchronization & Final Status
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${BL}▶ STEP 3: Test Synchronization & Verification${CL}"
read -r -p "$(echo -e "${YW}Would you like to run a test synchronization now? (Y/n): ${CL}")" RUN_TEST_SYNC
RUN_TEST_SYNC="${RUN_TEST_SYNC:-y}"

if [[ "$RUN_TEST_SYNC" =~ ^[Yy]$ ]]; then
  echo -e "\n${CY}Executing /opt/fit2garmin/sync.sh...${CL}"
  echo -e "${BOLD}------------------------------------------------------------${CL}"
  /opt/fit2garmin/sync.sh || true
  echo -e "${BOLD}------------------------------------------------------------${CL}"
fi

# Check cron job
echo -e "\n${BOLD}Automation Status:${CL}"
if [[ -f /etc/cron.d/gdrive2garmin ]]; then
  echo -e "${GN}[✓] Automated cron job active in /etc/cron.d/gdrive2garmin${CL}"
  echo -e "    Schedule: Runs every 15 minutes automatically."
  echo -e "    Log file: /var/log/gdrive2garmin.log"
fi

echo -e "\n${BOLD}================================================================${CL}"
echo -e "${GN}${BOLD}🎉 Setup Complete!${CL}"
echo -e "${BOLD}================================================================${CL}"
echo -e "Useful Commands:"
echo -e "  • Re-run setup wizard anytime:   ${BL}gdrive2garmin-setup${CL}"
echo -e "  • Run sync manually on-demand:   ${BL}/opt/fit2garmin/sync.sh${CL}"
echo -e "  • Monitor automated logs:        ${BL}tail -f /var/log/gdrive2garmin.log${CL}"
echo -e "  • Edit config manually:          ${BL}nano /opt/fit2garmin/config.py${CL}"
echo -e "${BOLD}================================================================${CL}\n"
