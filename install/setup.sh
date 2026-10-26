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
GARMIN_TOKEN_DIR="/root/.garminconnect"

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
mkdir -p "$INSTALL_DIR" "$INSTALL_DIR/fit_files" "$GARMIN_TOKEN_DIR"
chmod 700 "$GARMIN_TOKEN_DIR"

# Ensure modern garminconnect and curl_cffi are installed (replaces deprecated garth)
if ! python3 -c "import garminconnect" 2>/dev/null || ! python3 -c "import curl_cffi" 2>/dev/null; then
  echo -e "${CY}Installing modern Garmin Connect libraries (garminconnect & curl_cffi)...${CL}"
  pip3 install --break-system-packages garminconnect curl_cffi 2>/dev/null || pip3 install garminconnect curl_cffi
fi

# Self-update setup wizard from GitHub if online
if [[ "${SKIP_SETUP_UPDATE:-0}" != "1" ]]; then
  LATEST_SETUP=$(curl -fsSL https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/setup.sh 2>/dev/null || true)
  if [[ -n "$LATEST_SETUP" ]] && ! cmp -s <(echo "$LATEST_SETUP") "${BASH_SOURCE[0]}" 2>/dev/null; then
    echo -e "${CY}Updating setup wizard to latest version from GitHub...${CL}"
    echo "$LATEST_SETUP" > "${INSTALL_DIR}/setup.sh"
    chmod +x "${INSTALL_DIR}/setup.sh"
    export SKIP_SETUP_UPDATE=1
    exec "${INSTALL_DIR}/setup.sh" "$@"
  fi
fi

# Ensure latest fit2garmin engine is deployed
echo -e "${CY}Ensuring latest Garmin sync engine is installed...${CL}"
curl -fsSL "https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/fit2garmin_modern.py" -o "${INSTALL_DIR}/fit2garmin.py" 2>/dev/null || true
if [[ ! -s "${INSTALL_DIR}/fit2garmin.py" && -f "$(dirname "${BASH_SOURCE[0]}")/fit2garmin_modern.py" ]]; then
  cp "$(dirname "${BASH_SOURCE[0]}")/fit2garmin_modern.py" "${INSTALL_DIR}/fit2garmin.py"
fi
chmod +x "${INSTALL_DIR}/fit2garmin.py"

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
token_store_path = "~/.garminconnect"
'''

content = re.sub(r'garmin_email\s*=\s*.*', f'garmin_email = {repr(email)}', content)
content = re.sub(r'garmin_password\s*=\s*.*', f'garmin_password = {repr(password)}', content)
content = re.sub(r'folder_path\s*=\s*.*', 'folder_path = "/opt/fit2garmin/fit_files"', content)

if "token_store_path" not in content:
    content += '\ntoken_store_path = "~/.garminconnect"\n'

with open(config_path, "w") as f:
    f.write(content)
PYEOF

chmod 600 "$CONFIG_FILE"
echo -e "${GN}[✓] Garmin credentials saved securely.${CL}"

# Authenticate with Garmin using garminconnect + curl_cffi
echo -e "\n${CY}Authenticating with Garmin Connect...${CL}"
echo -e "${BL}(Note: If your account has Two-Factor Authentication (2FA/MFA) enabled,${CL}"
echo -e "${BL} you will receive a code. Enter it below if prompted.)${CL}\n"

GARMIN_AUTH_SUCCESS=0
python3 - <<PYEOF || GARMIN_AUTH_SUCCESS=1
import sys
import os
from garminconnect import (
    Garmin,
    GarminConnectAuthenticationError,
    GarminConnectConnectionError,
    GarminConnectTooManyRequestsError,
)

email = """${GARMIN_EMAIL}"""
password = """${GARMIN_PASSWORD}"""
token_dir = os.path.expanduser("~/.garminconnect")
os.makedirs(token_dir, exist_ok=True)
os.chmod(token_dir, 0o700)

try:
    client = Garmin(email, password)
    client.login(tokenstore=token_dir)
    display_name = getattr(client, "display_name", None) or getattr(client, "full_name", None) or email
    print(f"\033[01;32m[✓] Successfully authenticated as Garmin user: {display_name}\033[m")
    print(f"\033[01;32m[✓] Session tokens saved to: {token_dir}\033[m")
except GarminConnectTooManyRequestsError as e:
    print(f"\033[01;31m[!] Rate-limited by Garmin SSO (429): {e}\033[m", file=sys.stderr)
    print(f"\033[01;33m    Garmin is enforcing a temporary cooldown on this account/IP from previous attempts.\033[m", file=sys.stderr)
    print(f"\033[01;33m    Please allow 30-60 minutes for Garmin's cooldown to expire, then re-run setup.\033[m", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"\033[01;31m[!] Garmin authentication failed: {e}\033[m", file=sys.stderr)
    sys.exit(1)
PYEOF

if [[ $GARMIN_AUTH_SUCCESS -ne 0 ]]; then
  echo -e "\n${YW}[!] Note: If Garmin placed a temporary cooldown on your account, please wait before retrying.${CL}"
else
  chmod 600 "$GARMIN_TOKEN_DIR"/* 2>/dev/null || true
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

CLEANUP_NON_FIT="true"
FIT_RETENTION_DAYS="5"
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_CLEANUP=$(grep '^CLEANUP_NON_FIT=' "$ENV_FILE" | cut -d= -f2- | tr -d "\"'" || true)
  EXISTING_RETENTION=$(grep '^FIT_RETENTION_DAYS=' "$ENV_FILE" | cut -d= -f2- | tr -d "\"'" || true)
  if [[ -n "$EXISTING_CLEANUP" ]]; then CLEANUP_NON_FIT="$EXISTING_CLEANUP"; fi
  if [[ -n "$EXISTING_RETENTION" ]]; then FIT_RETENTION_DAYS="$EXISTING_RETENTION"; fi
fi

cat <<EOF > "$ENV_FILE"
RCLONE_REMOTE="${RCLONE_REMOTE_NAME}"
RCLONE_FOLDER="${RCLONE_FOLDER_NAME}"
CLEANUP_NON_FIT="${CLEANUP_NON_FIT}"
FIT_RETENTION_DAYS="${FIT_RETENTION_DAYS}"
EOF
chmod 600 "$ENV_FILE"
echo -e "${GN}[✓] Sync settings saved to ${ENV_FILE}${CL}"

# Ensure /opt/fit2garmin/sync.sh is up to date and sources sync.env
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
  python3 /opt/fit2garmin/fit2garmin.py || true
elif [[ -f /opt/fit2garmin/upload_file_garmin.py ]]; then
  python3 /opt/fit2garmin/upload_file_garmin.py || true
fi

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
EOF
chmod +x /opt/fit2garmin/sync.sh

# Test Google Drive connection
echo -e "\n${CY}Testing connection to ${RCLONE_REMOTE_NAME}:${RCLONE_FOLDER_NAME}...${CL}"
if rclone lsf "${RCLONE_REMOTE_NAME}:${RCLONE_FOLDER_NAME}" --max-depth 1 >/tmp/rclone_test.txt 2>&1; then
  FILE_COUNT=$(grep -c '\.fit$' /tmp/rclone_test.txt 2>/dev/null || true)
  TOTAL_FILES=$(wc -l < /tmp/rclone_test.txt 2>/dev/null || true)
  echo -e "${GN}[✓] Connected to Google Drive successfully!${CL}"
  echo -e "    Found ${GN}${FILE_COUNT}${CL} .fit file(s) (${TOTAL_FILES} items total) in '${RCLONE_FOLDER_NAME}'."
  rm -f /tmp/rclone_test.txt
else
  echo -e "${YW}[!] Note: Could not find folder '${RCLONE_FOLDER_NAME}' on Google Drive.${CL}"
  echo -e "${CY}    Available top-level folders found on your Google Drive:${CL}"
  rclone lsd "${RCLONE_REMOTE_NAME}:" 2>/dev/null | awk '{for(i=5;i<=NF;i++) printf "%s%s", $i, (i==NF?ORS:OFS)}' | sed 's/^/      • /' || true
  echo -e "    (You can edit ${ENV_FILE} or re-run 'gdrive2garmin-setup' with the exact folder name)\n"
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

# Check or update cron job
cat <<'CRONEOF' >/etc/cron.d/gdrive2garmin
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Active hours: Morning (06:00-11:30), Midday (14:00-15:30), Evening (17:00-19:30) every 30 minutes
0,30 6-11,14-15,17-19 * * * root /opt/fit2garmin/sync.sh >> /var/log/gdrive2garmin.log 2>&1
CRONEOF
chmod 644 /etc/cron.d/gdrive2garmin
echo -e "\n${BOLD}Automation Status:${CL}"
echo -e "${GN}[✓] Automated cron job active in /etc/cron.d/gdrive2garmin${CL}"
echo -e "    Schedule: Runs every 30 minutes during active hours (06:00-11:30, 14:00-15:30, 17:00-19:30)."
echo -e "    Log file: /var/log/gdrive2garmin.log"

echo -e "\n${BOLD}================================================================${CL}"
echo -e "${GN}${BOLD}🎉 Setup Complete!${CL}"
echo -e "${BOLD}================================================================${CL}"
echo -e "Useful Commands:"
echo -e "  • Re-run setup wizard anytime:   ${BL}gdrive2garmin-setup${CL}"
echo -e "  • Run sync manually on-demand:   ${BL}/opt/fit2garmin/sync.sh${CL}"
echo -e "  • Monitor automated logs:        ${BL}tail -f /var/log/gdrive2garmin.log${CL}"
echo -e "  • Edit config manually:          ${BL}nano /opt/fit2garmin/config.py${CL}"
echo -e "${BOLD}================================================================${CL}\n"
