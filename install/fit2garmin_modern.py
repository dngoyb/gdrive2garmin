#!/usr/bin/env python3
"""
fit2garmin_modern.py
Synchronizes and uploads .fit files to Garmin Connect using modern garminconnect + curl_cffi.
Replaces deprecated garth to avoid Cloudflare 429 Too Many Requests errors.
"""

import logging
import os
import sys
from pathlib import Path

# Add script directory to sys.path so config can be imported
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

try:
    import config
except ImportError:
    print("[!] Error: /opt/fit2garmin/config.py not found. Please run gdrive2garmin-setup.")
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
EMAIL = getattr(config, "garmin_email", "")
PASSWORD = getattr(config, "garmin_password", "")


def get_client() -> Garmin:
    """Authenticate with Garmin Connect using token persistence."""
    if not EMAIL or not PASSWORD:
        logger.error(
            "Garmin credentials are not configured in config.py. Run gdrive2garmin-setup."
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
            f"Garmin rate limit (429): {e}. Garmin is enforcing a temporary cooldown. Please wait 30-60 minutes."
        )
        sys.exit(1)
    except Exception as e:
        logger.error(f"Failed to authenticate with Garmin Connect: {e}")
        sys.exit(1)


def upload_fit_files(client: Garmin) -> None:
    """Scan folder and upload all .fit files."""
    folder = Path(FOLDER_PATH)
    if not folder.exists():
        logger.warning(f"Watch folder does not exist: {folder}")
        return

    fit_files = sorted(
        [p for p in folder.rglob("*") if p.is_file() and p.suffix.lower() == ".fit"],
        key=lambda x: x.stat().st_mtime,
    )

    if not fit_files:
        logger.info(f"No .fit files found in {folder}.")
        return

    logger.info(f"Found {len(fit_files)} .fit file(s) to process in {folder}.")
    uploaded_count = 0
    duplicate_count = 0
    error_count = 0

    for fit_file in fit_files:
        filename = fit_file.name
        try:
            logger.info(f"Uploading: {filename}...")
            result = client.upload_activity(str(fit_file))

            # Inspect detailed import result if available
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
            else:
                logger.error(f"[!] Failed to upload {filename}: {e}")
                error_count += 1

    logger.info(
        f"Sync summary: {uploaded_count} uploaded, {duplicate_count} duplicates, {error_count} errors."
    )


def main() -> None:
    client = get_client()
    upload_fit_files(client)


if __name__ == "__main__":
    main()
