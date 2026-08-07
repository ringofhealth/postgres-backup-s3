#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
source "${SCRIPT_DIR}/common.sh"

load_restore_environment
require_command pg_restore
require_command psql
require_command aws
require_command jq

selector="${1:-latest}"
manifest_key="$(resolve_manifest_key "$selector")"
run_dir="$(mktemp -d "${WORK_DIR%/}/restore.XXXXXX")"
manifest_file="${run_dir}/manifest.json"
archive_file="${run_dir}/archive"
dump_file="${run_dir}/database.dump"
passphrase_file="${run_dir}/passphrase"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  rm -rf "$run_dir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

download_manifest "$manifest_key" "$manifest_file"
validate_manifest "$manifest_file"

if [[ "$RESTORE_MODE" == "verify" ]]; then
  verify_remote_backup "$manifest_file" archive
  log info "backup verified without changing a database manifest=${manifest_key}"
  exit 0
fi

[[ "$RESTORE_CONFIRM" == "$RESTORE_TARGET_DATABASE" ]] ||
  die "database restore requires RESTORE_CONFIRM to exactly equal RESTORE_TARGET_DATABASE"

download_and_verify_object "$manifest_file" "$archive_file"
if [[ "$(jq -r '.encryption.enabled' "$manifest_file")" == "true" ]]; then
  encryption_enabled || die "PASSPHRASE or PASSPHRASE_FILE is required to restore this encrypted backup"
  write_passphrase_file "$passphrase_file"
  decrypt_archive "$archive_file" "$dump_file" "$passphrase_file"
else
  mv "$archive_file" "$dump_file"
fi
validate_pg_archive "$dump_file"

if [[ "$RESTORE_DROP_DATABASE" == "yes" ]]; then
  [[ "$RESTORE_CREATE_DATABASE" == "yes" ]] || die "RESTORE_DROP_DATABASE=yes requires RESTORE_CREATE_DATABASE=yes"
  log warning "dropping explicitly confirmed restore target database=${RESTORE_TARGET_DATABASE}"
  dropdb --if-exists \
    --host "$POSTGRES_HOST" --port "$POSTGRES_PORT" --username "$POSTGRES_USER" \
    --maintenance-db "$POSTGRES_MAINTENANCE_DATABASE" \
    "$RESTORE_TARGET_DATABASE"
fi

if [[ "$RESTORE_CREATE_DATABASE" == "yes" ]]; then
  log info "creating restore target database=${RESTORE_TARGET_DATABASE}"
  createdb \
    --host "$POSTGRES_HOST" --port "$POSTGRES_PORT" --username "$POSTGRES_USER" \
    --maintenance-db "$POSTGRES_MAINTENANCE_DATABASE" \
    "$RESTORE_TARGET_DATABASE"
fi

export RESTORE_ARCHIVE_FILE="$dump_file"
export RESTORE_MANIFEST_FILE="$manifest_file"
RESTORE_SOURCE_DATABASE="$(jq -r '.database.name' "$manifest_file")"
export RESTORE_SOURCE_DATABASE
export PGDATABASE="$RESTORE_TARGET_DATABASE"
run_hook restore_pre "$RESTORE_PRE_HOOK"

restore_args=(
  --exit-on-error
  --no-owner
  --no-privileges
  --jobs "$RESTORE_JOBS"
  --host "$POSTGRES_HOST"
  --port "$POSTGRES_PORT"
  --username "$POSTGRES_USER"
  --dbname "$RESTORE_TARGET_DATABASE"
)
if [[ "$RESTORE_CLEAN" == "yes" ]]; then
  restore_args+=(--clean --if-exists)
fi
if [[ -n "$RESTORE_EXTRA_OPTS" ]]; then
  IFS=' ' read -r -a extra_restore_args <<< "$RESTORE_EXTRA_OPTS"
  restore_args+=("${extra_restore_args[@]}")
fi

log info "restoring verified archive target_database=${RESTORE_TARGET_DATABASE} manifest=${manifest_key}"
pg_restore "${restore_args[@]}" "$dump_file"
run_hook restore_post "$RESTORE_POST_HOOK"
log info "restore completed target_database=${RESTORE_TARGET_DATABASE} manifest=${manifest_key}"
