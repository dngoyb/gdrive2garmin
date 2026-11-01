# ==============================================================================
# gdrive2garmin Dockerfile
# Synchronizes and uploads .fit files to Garmin Connect
# ==============================================================================

FROM debian:12 AS base

# Avoid interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# ==============================================================================
# Base Image Installation
# ==============================================================================

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    python3-pip \
    python3-dev \
    libffi-dev \
    rclone \
    git \
    cron \
    curl \
    logrotate \
    jq \
    su-exec \
    && rm -rf /var/lib/apt/lists/*

# ==============================================================================
# Python Dependencies
# ==============================================================================

# Install modern garminconnect and curl_cffi
RUN pip3 install --break-system-packages garminconnect curl_cffi 2>/dev/null || \
    pip3 install garminconnect curl_cffi

# Copy requirements if needed (optional)
# COPY requirements.txt /tmp/requirements.txt
# RUN pip3 install -r /tmp/requirements.txt

# ==============================================================================
# Directory Structure
# ==============================================================================

# Create installation directory
RUN mkdir -p /opt/fit2garmin/fit_files \
    /opt/fit2garmin/fit_files \
    /root/.garminconnect \
    /var/log

# Set permissions
RUN chmod 700 /root/.garminconnect \
    && chmod 755 /opt/fit2garmin

# ==============================================================================
# Copy Scripts and Engine
# ==============================================================================

# Copy the modern sync engine
COPY install/fit2garmin_modern.py /opt/fit2garmin/fit2garmin.py
RUN chmod +x /opt/fit2garmin/fit2garmin.py

# Copy the setup wizard
COPY install/setup.sh /opt/fit2garmin/setup.sh
RUN chmod +x /opt/fit2garmin/setup.sh

# Copy the sync script (will be configured by setup wizard)
COPY install/sync.env /opt/fit2garmin/sync.env
RUN chmod 600 /opt/fit2garmin/sync.env

# Copy config example
COPY install/config.example.py /opt/fit2garmin/config.py
RUN chmod 600 /opt/fit2garmin/config.py

# ==============================================================================
# Cron Configuration
# ==============================================================================

# Set up cron job for active hours scheduling
COPY --from=base /etc/cron.d/ /etc/cron.d/
RUN chmod 644 /etc/cron.d/*

# ==============================================================================
# Default Configuration (Placeholders)
# ==============================================================================

# Set default sync.env values (will be overridden by setup wizard)
RUN echo 'RCLONE_REMOTE="gdrive"' > /opt/fit2garmin/sync.env && \
    echo 'RCLONE_FOLDER="fit_files"' >> /opt/fit2garmin/sync.env && \
    echo 'CLEANUP_NON_FIT="true"' >> /opt/fit2garmin/sync.env && \
    echo 'FIT_RETENTION_DAYS="5"' >> /opt/fit2garmin/sync.env && \
    echo 'ALERT_WEBHOOK_URL=""' >> /opt/fit2garmin/sync.env && \
    echo 'ALERT_ON_SUCCESS="false"' >> /opt/fit2garmin/sync.env

# ==============================================================================
# Entrypoint
# ==============================================================================

# Default command shows help/usage if no args provided
CMD ["bash", "-c", "echo 'gdrive2garmin Docker container'; echo 'Run: gdrive2garmin-setup to configure'; echo 'Or use make target: make local-setup'"]