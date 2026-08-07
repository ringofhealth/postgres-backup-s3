#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
source "${SCRIPT_DIR}/common.sh"

load_s3_environment
: "${POSTGRES_DATABASE:=database}"
: "${BACKUP_NAME:=$POSTGRES_DATABASE}"
validate_object_component "$BACKUP_NAME" "BACKUP_NAME"
require_command aws
require_command jq

printf 'LAST_MODIFIED\tMANIFEST_KEY\n'
list_manifest_entries
