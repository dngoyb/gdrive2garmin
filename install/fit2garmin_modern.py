#!/usr/bin/env python3
"""
fit2garmin_modern.py
Synchronizes and uploads .fit files to Garmin Connect using modern garminconnect + curl_cffi.
Includes history tracking to prevent uploading old/already processed files.
"""

import argparse
from datetime import datetime
import logging
import os
from pathlib import Path
import sys

# Add script directory to sys.path so config can be imported
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

# Load optional environment file
ENV_FILE = Path("/opt/fit2garmin/sync.env")
if ENV_FILE.exists():
  try:
    for line in ENV_FILE.read_text().splitlines():
      line = line.strip()
      if line and not line.startswith("#") and "=" in line:
        k, v = line.split("=", 1)
        os.environ.setdefault(k.strip(), v.strip().strip("\"'"))
  except Exception:
    pass

try:
  import config
except ImportError:
  print(
      "[!] Error: /opt/fit2garmin/config.py not found. Please run"
      " gdrive2garmin-setup."
  )
  sys.exit(1)

try:
  from garminconnect import (
      Garmin,
      GarminConnectAuthenticationError,
      GarminConnectConnectionError,
      GarminConnectTooManyRequestsError,
  )
except ImportError:
  print("[!] Error: garminconnect library not installed.")
  print("    Run: pip3 install --break-system-packages garminconnect curl_cffi")
  sys.exit(1)

logging.basicConfig(
    level=logging.INFO if getattr(config, "debug", True) else logging.WARNING,
    format="[%(asctime)s] %(levelname)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("fit2garmin")

TOKEN_STORE = os.path.expanduser(
    getattr(config, "token_store_path", "~/.garminconnect")
)
FOLDER_PATH = getattr(config, "folder_path", "/opt/fit2garmin/fit_files")
TRACKING_FILE = Path(
    os.path.expanduser(
        getattr(config, "tracking_file", "/opt/fit2garmin/.processed_files")
    )
)
EMAIL = getattr(config, "garmin_email", "")
PASSWORD = getattr(config, "garmin_password", "")


def load_processed_files() -> set[str]:
  """Load set of already uploaded / processed filenames."""
  if TRACKING_FILE.exists():
    try:
      return {
          line.strip()
          for line in TRACKING_FILE.read_text().splitlines()
          if line.strip()
      }
    except Exception as e:
      logger.warning(f"Could not read tracking file {TRACKING_FILE}: {e}")
  return set()


def record_processed_file(filename: str) -> None:
  """Append filename to the tracking file."""
  try:
    with open(TRACKING_FILE, "a") as f:
      f.write(f"{filename}\n")
  except Exception as e:
    logger.warning(f"Could not update tracking file {TRACKING_FILE}: {e}")


def get_cutoff_timestamp() -> float | None:
  """Get start cutoff timestamp if START_DATE or START_TIMESTAMP is specified."""
  start_str = os.getenv("START_DATE") or getattr(config, "start_date", None)
  if not start_str:
    return None

  start_str = str(start_str).strip()
  if start_str.lower() == "now":
    return datetime.now().timestamp()

  for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M", "%Y-%m-%d"):
    try:
      dt = datetime.strptime(start_str, fmt)
      return dt.timestamp()
    except ValueError:
      continue

  logger.warning(
      f"Could not parse START_DATE '{start_str}'. Format should be YYYY-MM-DD"
  )
  return None


def get_client() -> Garmin:
  """Authenticate with Garmin Connect using token persistence."""
  if not EMAIL or not PASSWORD:
    logger.error(
        "Garmin credentials are not configured in config.py. Run"
        " gdrive2garmin-setup."
    )
    sys.exit(1)

  os.makedirs(TOKEN_STORE, exist_ok=True)
  os.chmod(TOKEN_STORE, 0o700)

  client = Garmin(EMAIL, PASSWORD)
  logger.info("Connecting to Garmin Connect...")

  try:
    client.login(tokenstore=TOKEN_STORE)
    display_name = (
        getattr(client, "display_name", None)
        or getattr(client, "full_name", None)
        or EMAIL
    )
    logger.info(f"Authenticated successfully as: {display_name}")
    return client
  except GarminConnectTooManyRequestsError as e:
    logger.error(
        f"Garmin rate limit (429): {e}. Garmin is enforcing a temporary"
        " cooldown. Please wait 30-60 minutes."
    )
    sys.exit(1)
  except Exception as e:
    logger.error(f"Failed to authenticate with Garmin Connect: {e}")
    sys.exit(1)


def mark_all_current_files_as_processed() -> None:
  """Mark all currently existing .fit files as processed so they are not uploaded."""
  folder = Path(FOLDER_PATH)
  if not folder.exists():
    print(f"[!] Folder does not exist: {folder}")
    return

  fit_files = sorted(
      [
          p.name
          for p in folder.rglob("*")
          if p.is_file() and p.suffix.lower() == ".fit"
      ]
  )

  processed = load_processed_files()
  added = 0
  for f in fit_files:
    if f not in processed:
      record_processed_file(f)
      processed.add(f)
      added += 1

  print(
      f"[✓] Successfully marked {added} existing .fit file(s) as processed (out"
      f" of {len(fit_files)} total)."
  )
  print(
      "[✓] Starting now: only NEW incoming files will be uploaded to Garmin"
      " Connect."
  )


def upload_fit_files(client: Garmin) -> None:
  """Scan folder and upload only new, unprocessed .fit files."""
  folder = Path(FOLDER_PATH)
  if not folder.exists():
    logger.warning(f"Watch folder does not exist: {folder}")
    return

  fit_files = sorted(
      [
          p
          for p in folder.rglob("*")
          if p.is_file() and p.suffix.lower() == ".fit"
      ],
      key=lambda x: x.stat().st_mtime,
  )

  if not fit_files:
    logger.info(f"No .fit files found in {folder}.")
    return

  processed = load_processed_files()
  cutoff = get_cutoff_timestamp()

  to_upload = []
  for fit_file in fit_files:
    filename = fit_file.name

    # Skip if already marked as processed
    if filename in processed:
      continue

    # Skip if older than cutoff date
    if cutoff and fit_file.stat().st_mtime < cutoff:
      logger.info(
          f"[-] Skipping file before start date cutoff ({filename}). Marking"
          " processed."
      )
      record_processed_file(filename)
      processed.add(filename)
      continue

    to_upload.append(fit_file)

  if not to_upload:
    logger.info(
        f"All {len(fit_files)} file(s) in {folder} are already processed."
        " Waiting for new files."
    )
    return

  logger.info(
      f"Found {len(to_upload)} new .fit file(s) to upload out of"
      f" {len(fit_files)} total."
  )
  uploaded_count = 0
  duplicate_count = 0
  error_count = 0

  for fit_file in to_upload:
    filename = fit_file.name
    try:
      logger.info(f"Uploading new activity: {filename}...")
      result = client.upload_activity(str(fit_file))

      # Check detailed import result
      import_res = result if isinstance(result, dict) else {}
      detailed = import_res.get("detailedImportResult", {})
      failures = detailed.get("failures", [])

      is_duplicate = False
      for failure in failures:
        for msg in failure.get("messages", []):
          code = msg.get("code")
          content = msg.get("content", "").lower()
          if code == 202 or "already" in content or "duplicate" in content:
            is_duplicate = True
            break

      if is_duplicate:
        logger.info(f"[-] Already uploaded (duplicate): {filename}")
        duplicate_count += 1
      else:
        logger.info(f"[✓] Successfully uploaded: {filename}")
        uploaded_count += 1

      # Record file so it is never re-uploaded
      record_processed_file(filename)
      processed.add(filename)

    except Exception as e:
      err_str = str(e).lower()
      if (
          "already" in err_str
          or "duplicate" in err_str
          or "409" in err_str
          or "202" in err_str
      ):
        logger.info(f"[-] Already uploaded (duplicate): {filename}")
        duplicate_count += 1
        record_processed_file(filename)
        processed.add(filename)
      else:
        logger.error(f"[!] Failed to upload {filename}: {e}")
        error_count += 1

  logger.info(
      f"Sync summary: {uploaded_count} uploaded, {duplicate_count} duplicates,"
      f" {error_count} errors."
  )


def main() -> None:
  parser = argparse.ArgumentParser(
      description="Upload .fit files to Garmin Connect"
  )
  parser.add_argument(
      "--mark-all-processed",
      action="store_true",
      help="Mark all current .fit files as processed so they are skipped",
  )
  args = parser.parse_args()

  if args.mark_all_processed:
    mark_all_current_files_as_processed()
    return

  client = get_client()
  upload_fit_files(client)


if __name__ == "__main__":
  main()
