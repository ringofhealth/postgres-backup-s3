#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
source "${SCRIPT_DIR}/common.sh"

load_restore_environment
require_command aws
require_command jq
require_command pg_restore
require_command sha256sum
selector="${1:-latest}"
mode="${2:-archive}"
manifest_key="$(resolve_manifest_key "$selector")"
run_dir="$(mktemp -d "${WORK_DIR%/}/verify-manifest.XXXXXX")"
trap 'rm -rf "$run_dir"' EXIT INT TERM
manifest_file="${run_dir}/manifest.json"

download_manifest "$manifest_key" "$manifest_file"
verify_remote_backup "$manifest_file" "$mode"
log info "backup verification passed manifest=${manifest_key} mode=${mode}"
jq . "$manifest_file"
