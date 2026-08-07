#!/usr/bin/env bash

# Backwards-compatible environment entrypoint. New scripts source common.sh and
# call one of its load_*_environment functions directly.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
source "${SCRIPT_DIR}/common.sh"
load_backup_environment
