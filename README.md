# gdrive2garmin

**Token-optimized CLI proxy** - Synchronizes and uploads .fit activity files from Google Drive to Garmin Connect.

![GitHub Stars](https://img.shields.io/github/stars/dngoyb/gdrive2garmin?style=for-the-badge)
![GitHub Forks](https://img.shields.io/github/forks/dngoyb/gdrive2garmin?style=for-the-badge)
![GitHub License](https://img.shields.io/github/license/dngoyb/gdrive2garmin?style=for-the-badge)

---

## 📋 Overview

gdrive2garmin automates the process of syncing `.fit` activity/health files from **Google Drive** (via `rclone`) and automatically uploading them to **Garmin Connect** using `garminconnect` + `curl_cffi` (with TLS fingerprint impersonation to bypass Garmin's Cloudflare 429 blocks).

### 🎯 Primary Use Case
External health devices/apps export `.fit` files to Google Drive → gdrive2garmin syncs them to Garmin Connect automatically.

### 🏓 Supported Deployment Methods
| Method | Requirements | Best For |
|--------|-------------|----------|
| **Proxmox VE LXC** | Proxmox server | Full-featured, always-on container |
| **Docker** | Docker engine | Easy cross-platform deployment |
| **Local (Bash)** | Linux/macOS/WSL | Quick setup, no virtualization |
| **Makefile** | Any OS with `make` | Convenience targets |

---

## 🚀 Quick Start by Deployment Method

### 📦 Option 1: Proxmox VE (Original Method)

**Run this command in your Proxmox VE Node Shell** to create and configure the container:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/ct/gdrive2garmin.sh)"
```

**What this does:**
- Creates an LXC container with 1 CPU, 512MB RAM, 4GB Disk (Debian 12)
- Installs all dependencies (python3, rclone, git, cron, curl, jq, logrotate)
- Clones fit2garmin from GitHub
- Deploys the modern sync engine (fit2garmin_modern.py)
- Configures log rotation
- Deploys sync.sh with alert functionality
- Deploys the setup wizard (gdrive2garmin-setup)
- Sets up cron automation (every 30 min during active hours)

**After container creation, access the console and complete setup:**

```bash
# Access container console (from Proxmox host)
pct enter <CTID>

# Inside the container, run the interactive setup wizard
gdrive2garmin-setup
# Or: bash -c "$(curl -fsSL https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/setup.sh)"
```

The setup wizard will guide you through:
1. ✅ Garmin Connect credentials & authentication (with 2FA/MFA support)
2. ✅ Google Drive rclone configuration & folder selection
3. ✅ Alert webhook configuration (ntfy.sh, Discord, Slack, Pushover)
4. ✅ Live test synchronization & cron validation

---

### 🐳 Option 2: Docker (New)

```bash
# Using Docker CLI
docker build -t gdrive2garmin:latest .
docker run -d --name gdrive2garmin --restart unless-stopped gdrive2garmin:latest

# Or using Docker Compose
docker compose up -d
```

**Dockerfile** included - builds on Debian 12 with all dependencies pre-installed.

---

### 🐧 Option 3: Local/Bash (No Virtualization)

```bash
# Using Makefile (recommended)
make local-setup-wizard    # Interactive configuration (requires root)
make local-run             # Run sync manually
make logs                  # View sync logs
make rtk-gain              # Show token savings analytics
```

Or step-by-step:
```bash
bash install/gdrive2garmin-install.sh    # Install dependencies & engine
bash install/setup.sh                     # Interactive setup wizard
/opt/fit2garmin/sync.sh                   # Run sync manually
```

---

### ⚙️ Option 4: Manual Configuration

```bash
# Install dependencies manually
apt-get install python3-pip rclone git curl jq
pip3 install garminconnect curl_cffi

# Run setup wizard
gdrive2garmin-setup

# Or manual config
nano /opt/fit2garmin/config.py    # Set garmin_email/password
/opt/fit2garmin/sync.sh           # Run sync
```

---

## 📦 Repository Structure

```
.
├── ct/                        # Proxmox VE community script
│   └── gdrive2garmin.sh
├── install/                   # Installation scripts
│   ├── gdrive2garmin-install.sh  # Packages & config (local or Proxmox)
│   ├── fit2garmin_modern.py      # Modern sync engine
│   └── setup.sh                  # Setup wizard
├── Makefile                  # Convenience targets (new)
├── Dockerfile               # Docker image (new)
├── docker-compose.yml       # Docker Compose (new)
└── README.md                # Documentation
```

---

## ⚙️ Configuration

### sync.env Settings (`/opt/fit2garmin/sync.env`)

| Variable | Default | Description |
|----------|---------|-------------|
| `RCLONE_REMOTE` | `gdrive` | rclone remote name |
| `RCLONE_FOLDER` | `fit_files` | Google Drive folder name |
| `CLEANUP_NON_FIT` | `true` | Remove `.gpx/.kml/.tcx/.csv` from Drive |
| `FIT_RETENTION_DAYS` | `5` | Purge .fit files older than N days |
| `ALERT_WEBHOOK_URL` | *(empty)* | Webhook for failure alerts (ntfy.sh, Discord, Slack) |
| `ALERT_ON_SUCCESS` | `false` | Also alert on successful syncs |

### config.py Settings (`/opt/fit2garmin/config.py`)

```python
debug = True

garmin_email = "your_garmin_email@example.com"
garmin_password = "your_garmin_password"

folder_path = "/opt/fit2garmin/fit_files"
token_store_path = "~/.garminconnect"
```

---

## ⏰ Automation & Scheduling

### Cron Job (`/etc/cron.d/gdrive2garmin`)

```cron
# Active hours: Morning (06:00-11:30), Midday (14:00-15:30), Evening (17:00-19:30) every 30 minutes
0,30 6-11,14-15,17-19 * * * root /opt/fit2garmin/sync.sh >> /var/log/gdrive2garmin.log 2>&1
```

- **Frequency**: Every 30 minutes during active workout windows
- **Lazy Garmin Authentication**: sync engine inspects local folder first; if no new .fit files, exits immediately without authenticating (prevents Cloudflare 429 rate limiting)
- **Automated Google Drive Cleanup**: Controls via sync.env
- **Log Rotation**: Daily rotation, 14 days retention, compressed (`/etc/logrotate.d/gdrive2garmin`)
- **Failure Alerting**: JSON webhook alerts via ALERT_WEBHOOK_URL

---

## 📁 Full Repository Structure

```
.
├── ct/                        # Proxmox VE community script
│   └── gdrive2garmin.sh
├── install/                   # Installation scripts
│   ├── gdrive2garmin-install.sh  # Packages, dependencies, checksum-verified downloads
│   ├── fit2garmin_modern.py      # Modern Garmin sync engine
│   └── setup.sh                # In-container setup wizard
├── Makefile                 # Convenience targets (local setup, docker, logs, etc.)
├── Dockerfile               # Debian 12-based Docker image
├── docker-compose.yml       # Docker Compose configuration
├── sync.env                 # Runtime configuration (generated by setup)
├── config.py                # Garmin credentials (created by setup)
├── fit2garmin.py            # Modern sync engine (deployed by install script)
├── .processed_files         # Tracking file (created by sync)
└── README.md                # Documentation
```

---

## 🔄 Updates & Maintenance

### Using Makefile:
```bash
make local-setup-wizard    # Re-run setup wizard
make local-run             # Run sync to pick up new files
```

### Using Docker:
```bash
docker compose down && docker compose up -d  # Redeploy with new image
# Or rebuild
make docker-build
make docker-run
```

### Using Proxmox:
```bash
# Re-run the community script
bash -c "$(curl -fsSL https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/ct/gdrive2garmin.sh)"
```

### Manual Updates:
```bash
pip3 install --upgrade --break-system-packages garminconnect curl_cffi
curl -fsSL https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/fit2garmin_modern.py -o /opt/fit2garmin/fit2garmin.py
chmod +x /opt/fit2garmin/fit2garmin.py
```

---

## 🛠️ rtk (Token Optimization)

This project uses **RTK** (Rust Token Killer) for token-optimized CLI operations:

```bash
rtk gain              # Show token savings analytics
rtk gain --history    # Show command usage history with savings
```

> ⚠️ **Name collision**: If `rtk gain` fails, you may have `reachingforthejack/rtk` (Rust Type Kit) installed instead.

---

## 📜 License

Distributed under the **MIT License**. See `LICENSE` for more information.

---

## 👨‍💻 Credits

- [`garminconnect`](https://github.com/cyberjunky/python-garminconnect) by [cyberjunky]
- [`curl_cffi`](https://github.com/lexiforest/curl_cffi) for browser TLS fingerprint impersonation
- Base orchestration inspired by [Community-Scripts / Proxmox VE Helper-Scripts]
- RTK integration per [home/ngoyb/.claude/RTK.md]