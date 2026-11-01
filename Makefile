# ==============================================================================
# gdrive2garmin Makefile
# Convenience targets for local development and deployment
# ==============================================================================

# Variables (can be overridden with make VAR=value)
INSTALL_DIR ?= /opt/fit2garmin
ENV_FILE ?= $(INSTALL_DIR)/sync.env
CONFIG_FILE ?= $(INSTALL_DIR)/config.py

.PHONY: all help local-setup local-run local-test local-clean logs rtk-gain

all: help ## Show this help message

## === Local Setup & Installation ===

help: ## Show this help message
	@echo "gdrive2garmin Makefile - Available targets:"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' \
		| sort
	@echo ""

local-setup: ## Install gdrive2garmin on local machine (requires root/sudo)
	@echo "=== gdrive2garmin Local Installation ==="
	@if [ "$(id -u)" -ne 0 ]; then \
		echo -e "${RD}[!] Must be root (or sudo) for local installation${CL}"; \
		exit 1; \
	fi
	@bash install/gdrive2garmin-install.sh
	@echo ""
	@echo "=== Installation Complete ==="
	@echo "Run 'make local-setup-wizard' to configure"

local-setup-wizard: ## Run the interactive setup wizard
	@echo "=== gdrive2garmin Setup Wizard ==="
	@if [ "$(id -u)" -ne 0 ]; then \
		echo -e "${RD}[!] Must be root (or sudo)${CL}"; \
		exit 1; \
	fi
	@bash install/setup.sh

## === Running & Operations ===

local-run: ## Run sync manually (same as /opt/fit2garmin/sync.sh)
	@echo "=== Running gdrive2garmin Sync ==="
	@if [ ! -f $(INSTALL_DIR)/sync.sh ]; then \
		echo -e "${RD}[!] sync.sh not found. Run 'make local-setup-wizard' first${CL}"; \
		exit 1; \
	fi
	@bash $(INSTALL_DIR)/sync.sh

local-test: ## Run a test sync (quick verification)
	@echo "=== Running Test Synchronization ==="
	@bash $(INSTALL_DIR)/sync.sh 2>&1 | tail -30

logs: ## Show the last 50 lines of sync logs
	@if [ -f /var/log/gdrive2garmin.log ]; then \
		tail -50 /var/log/gdrive2garmin.log; \
	else \
		echo "No log file found at /var/log/gdrive2garmin.log"; \
	fi

## === Development & Debugging ===

rtk-gain: ## Show token savings analytics (per RTK.md)
	@echo "=== gdrive2garmin Token Savings ==="
	@if command -v rtk >/dev/null 2>&1; then \
		rtk gain; \
	else \
		echo "rtk not installed. Install: pip install rust-token-kit || use rtk gain --history"; \
	fi

clean: ## Clean up temporary/generated files
	@echo "=== Cleaning gdrive2garmin ==="
	@rm -f /tmp/install_update.sh /tmp/sync.env /tmp/setup_latest.sh /tmp/rclone_test.txt
	@echo "Cleaned temporary files"

## === Docker Targets ===

docker-build: ## Build gdrive2garmin Docker image
	@echo "=== Building gdrive2garmin Docker Image ==="
	@docker build -t gdrive2garmin:latest .
	@echo "Image built: gdrive2garmin:latest"

docker-run: ## Run gdrive2garmin in Docker container
	@echo "=== Running gdrive2garmin Docker Container ==="
	@docker run -d \
		--name gdrive2garmin \
		--restart unless-stopped \
		-v /var/run/docker.sock:/var/run/docker.sock:ro \
		-v $(PWD)/fit_files:$(INSTALL_DIR)/fit_files \
		-v /var/log/gdrive2garmin.log:/var/log/gdrive2garmin.log \
		-p 8080:8080 \
		gdrive2garmin:latest
	@echo "Container started: gdrive2garmin"

docker-stop: ## Stop the Docker container
	@echo "=== Stopping gdrive2garmin Docker Container ==="
	@docker stop gdrive2garmin 2>/dev/null || true
	@docker rm gdrive2garmin 2>/dev/null || true
	@echo "Container stopped and removed"

docker-logs: ## Show Docker container logs
	@docker logs gdrive2garmin 2>/dev/null || echo "Container not running"

## === Garmin Connection ===

auth-test: ## Test Garmin authentication
	@echo "=== Testing Garmin Authentication ==="
	@if [ -f $(CONFIG_FILE) ]; then \
		python3 -c "import sys; sys.path.insert(0, '$(INSTALL_DIR)'); import config; print(f'Email: {getattr(config, \"garmin_email\", \"NOT SET\")}')"; \
	else \
		echo "Config file not found at $(CONFIG_FILE)"; \
	fi

status: ## Show current configuration status
	@echo "=== gdrive2garmin Status ==="
	@echo "Installation directory: $(INSTALL_DIR)"
	@if [ -f $(ENV_FILE) ]; then \
		echo "Config file: $(ENV_FILE) - EXIST"; \
		cat $(ENV_FILE) | grep -v '^#' | grep -v '^$'; \
	else \
		echo "Config file: $(ENV_FILE) - NOT FOUND"; \
	fi
	@if [ -f $(INSTALL_DIR)/sync.sh ]; then \
		echo "sync.sh: EXISTS"; \
	else \
		echo "sync.sh: NOT FOUND"; \
	fi
	@echo "Logs: /var/log/gdrive2garmin.log"