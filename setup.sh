#!/usr/bin/env bash
# Entrypoint for gdrive2garmin setup inside the LXC container
exec bash -c "$(curl -fsSL https://raw.githubusercontent.com/dngoyb/gdrive2garmin/main/install/setup.sh)" "$@"
