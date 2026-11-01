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

# Ensure jq is installed for secure JSON construction
if ! command -v jq >/dev/null 2>&1; then
  echo -e "${CY}Installing jq for secure JSON handling...${CL}"
  apt-get update -qq && apt-get install -y -qq jq 2>/dev/null || true
fi

# Ensure modern garminconnect and curl_cffi are installed (replaces deprecated garth)
if ! python3 -c "import garminconnect" 2>/dev/null || ! python3 -c "import curl_cffi" 2>/dev/null; then
  echo -e "${CY}Installing modern Garmin Connect libraries (garminconnect & curl_cffi)...${CL}"
  pip3 install --break-system-packages garminconnect curl_cffi 2>/dev/null || pip3 install garminconnect curl_cffi
fi

CURRENT_SCRIPT="${BASH_SOURCE[0]:-}"

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
    echo -e "${RD}[!] Checksum verification failed for $url${CL}" >&2
    rm -f "$output"
    return 1
  fi
  return 0
}

# Expected SHA256 checksums for release files (update these when releasing new versions)
# These should be updated via CI/CD when publishing releases
SETUP_SH_SHA256="PLACEHOLDER_UPDATE_ON_RELEASE"
FIT2GARMIN_SHA256="PLACEHOLDER_UPDATE_ON_RELEASE"

# Self-update setup wizard if executed from an existing local file and online
if [[ -n "$CURRENT_SCRIPT" && -f "$CURRENT_SCRIPT" && "${SKIP_SETUP_UPDATE:-0}" != "1" ]]; then
  LATEST_SETUP="/tmp/setup_latest.sh"
  if safe_download "https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/setup.sh" \
      "$LATEST_SETUP" "$SETUP_SH_SHA256"; then
    if ! cmp -s "$LATEST_SETUP" "$CURRENT_SCRIPT" 2>/dev/null; then
      echo -e "${CY}Updating setup wizard to latest version from GitHub...${CL}"
      cp "$LATEST_SETUP" "${INSTALL_DIR}/setup.sh"
      chmod +x "${INSTALL_DIR}/setup.sh"
      export SKIP_SETUP_UPDATE=1
      exec "${INSTALL_DIR}/setup.sh" "$@"
    fi
  else
    echo -e "${YW}[!] Failed to verify latest setup.sh, using current version${CL}"
  fi
  rm -f "$LATEST_SETUP"
fi

# Ensure latest fit2garmin engine is deployed
echo -e "${CY}Ensuring latest Garmin sync engine is installed...${CL}"
if safe_download "https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/fit2garmin_modern.py" \
    "${INSTALL_DIR}/fit2garmin.py" "$FIT2GARMIN_SHA256"; then
  chmod +x "${INSTALL_DIR}/fit2garmin.py"
else
  echo -e "${YW}[!] Failed to verify latest fit2garmin.py, using local/fallback${CL}"
  if [[ ! -s "${INSTALL_DIR}/fit2garmin.py" && -n "${CURRENT_SCRIPT}" && -f "$(dirname "${CURRENT_SCRIPT}")/fit2garmin_modern.py" ]]; then
    cp "$(dirname "${CURRENT_SCRIPT}")/fit2garmin_modern.py" "${INSTALL_DIR}/fit2garmin.py"
  fi
  chmod +x "${INSTALL_DIR}/fit2garmin.py"
fi

# Persist script in /opt/fit2garmin and symlink to PATH if not already there
if [[ ! -f "${INSTALL_DIR}/setup.sh" ]] || [[ "${CURRENT_SCRIPT}" != "${INSTALL_DIR}/setup.sh" ]]; then
  if [[ -n "${CURRENT_SCRIPT}" && -f "${CURRENT_SCRIPT}" ]]; then
    cp "${CURRENT_SCRIPT}" "${INSTALL_DIR}/setup.sh" 2>/dev/null || true
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
ALERT_WEBHOOK_URL=""
ALERT_ON_SUCCESS="false"
if [[ -f "$ENV_FILE" ]]; then
  EXISTING_CLEANUP=$(grep '^CLEANUP_NON_FIT=' "$ENV_FILE" | cut -d= -f2- | tr -d "\"'" || true)
  EXISTING_RETENTION=$(grep '^FIT_RETENTION_DAYS=' "$ENV_FILE" | cut -d= -f2- | tr -d "\"'" || true)
  EXISTING_ALERT_URL=$(grep '^ALERT_WEBHOOK_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d "\"'" || true)
  EXISTING_ALERT_SUCCESS=$(grep '^ALERT_ON_SUCCESS=' "$ENV_FILE" | cut -d= -f2- | tr -d "\"'" || true)
  if [[ -n "$EXISTING_CLEANUP" ]]; then CLEANUP_NON_FIT="$EXISTING_CLEANUP"; fi
  if [[ -n "$EXISTING_RETENTION" ]]; then FIT_RETENTION_DAYS="$EXISTING_RETENTION"; fi
  if [[ -n "$EXISTING_ALERT_URL" ]]; then ALERT_WEBHOOK_URL="$EXISTING_ALERT_URL"; fi
  if [[ -n "$EXISTING_ALERT_SUCCESS" ]]; then ALERT_ON_SUCCESS="$EXISTING_ALERT_SUCCESS"; fi
fi

# Alert configuration
echo -e "\n${BOLD}Failure Alert Webhook (Optional):${CL}"
echo -e "Configure a webhook URL to receive alerts on sync failures (and optionally successes)."
echo -e "Supported: ntfy.sh, Pushover, Discord, Slack, generic JSON webhooks."
echo -e "${BL}Must be an HTTPS URL. Localhost and private IPs are blocked for security.${CL}"

# Validation function for webhook URL (matches the one in sync.sh)
validate_webhook_url() {
  local url="$1"
  [[ "$url" =~ ^https:// ]] || return 1
  [[ "$url" =~ (^|://)(localhost|127\.|10\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.|169\.254\.|169\.254\.169\.254) ]] && return 1
  return 0
}

read -r -p "$(echo -e "${YW}Alert webhook URL [current: ${ALERT_WEBHOOK_URL:-none}]: ${CL}")" INPUT_ALERT_URL
if [[ -n "$INPUT_ALERT_URL" ]]; then
  if ! validate_webhook_url "$INPUT_ALERT_URL"; then
    echo -e "${RD}[!] Invalid webhook URL. Must be HTTPS and cannot point to localhost or private IPs.${CL}"
  else
    ALERT_WEBHOOK_URL="$INPUT_ALERT_URL"
    read -r -p "$(echo -e "${YW}Also alert on successful syncs? (y/N): ${CL}")" ALERT_ON_SUCCESS_INPUT
    ALERT_ON_SUCCESS_INPUT="${ALERT_ON_SUCCESS_INPUT:-n}"
    if [[ "$ALERT_ON_SUCCESS_INPUT" =~ ^[Yy]$ ]]; then
      ALERT_ON_SUCCESS="true"
    fi
  fi
fi

cat <<EOF > "$ENV_FILE"
RCLONE_REMOTE="${RCLONE_REMOTE_NAME}"
RCLONE_FOLDER="${RCLONE_FOLDER_NAME}"
CLEANUP_NON_FIT="${CLEANUP_NON_FIT}"
FIT_RETENTION_DAYS="${FIT_RETENTION_DAYS}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL}"
ALERT_ON_SUCCESS="${ALERT_ON_SUCCESS}"
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
