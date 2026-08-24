#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
source "${SCRIPT_DIR}/common.sh"

load_backup_environment
require_command pg_dump
require_command pg_restore
require_command aws
require_command jq
require_command flock

exec 9>"${STATE_DIR%/}/backup.lock"
if ! flock --nonblock 9; then
  log warning "another backup owns the lock; skipping overlapping run"
  exit 0
fi

if (( BACKUP_JITTER_SECONDS > 0 )); then
  jitter=$(( RANDOM % (BACKUP_JITTER_SECONDS + 1) ))
  log info "applying configured backup jitter seconds=${jitter}"
  sleep "$jitter"
fi

run_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
timestamp="$(date -u +'%Y-%m-%dT%H-%M-%SZ')"
run_dir="$(mktemp -d "${WORK_DIR%/}/backup.XXXXXX")"
passphrase_file="${run_dir}/passphrase"
archive_suffix="dump"
if encryption_enabled; then archive_suffix="dump.gpg"; fi

object_key="$(prefixed_key "${BACKUP_NAME}_${timestamp}.${archive_suffix}")"
manifest_key="${object_key}.manifest.json"
temporary_key="$(prefixed_key ".incomplete/${BACKUP_NAME}_${timestamp}_${run_id}.${archive_suffix}")"
temporary_uploaded="no"
published="no"

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ "$temporary_uploaded" == "yes" ]]; then
    aws_command s3 rm "$(s3_uri "$temporary_key")" --only-show-errors >/dev/null 2>&1 || true
  fi
  if [[ "$published" != "yes" && -n "${object_key:-}" ]]; then
    aws_command s3 rm "$(s3_uri "$object_key")" --only-show-errors >/dev/null 2>&1 || true
  fi
  if [[ "${KEEP_LOCAL_BACKUP:-no}" != "yes" || $status -ne 0 ]]; then
    rm -rf "$run_dir"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if encryption_enabled; then
  write_passphrase_file "$passphrase_file"
fi

build_pg_dump_args
run_hook backup_pre "$BACKUP_PRE_HOOK"

log info "starting logical backup database=${POSTGRES_DATABASE} mode=${BACKUP_MODE} verify=${BACKUP_VERIFY_MODE}"
started_epoch="$(date +%s)"
server_version="$(database_server_version)"

upload_expected_args=()
if [[ -n "$BACKUP_EXPECTED_SIZE_BYTES" ]]; then
  upload_expected_args+=(--expected-size "$BACKUP_EXPECTED_SIZE_BYTES")
fi
s3_transfer_args

if [[ "$BACKUP_MODE" == "stream" ]]; then
  hash_pipe="${run_dir}/hash.pipe"
  size_pipe="${run_dir}/size.pipe"
  hash_file="${run_dir}/sha256"
  size_file="${run_dir}/bytes"
  mkfifo "$hash_pipe" "$size_pipe"

  (sha256sum < "$hash_pipe" | awk '{print $1}' > "$hash_file") &
  hash_pid=$!
  (wc -c < "$size_pipe" | tr -d '[:space:]' > "$size_file") &
  size_pid=$!

  if ! produce_archive_stream "$passphrase_file" |
      tee "$hash_pipe" "$size_pipe" |
      aws_command s3 cp - "$(s3_uri "$temporary_key")" \
        "${S3_TRANSFER_ARGS[@]}" "${upload_expected_args[@]}"; then
    wait "$hash_pid" "$size_pid" || true
    die "streaming pg_dump upload failed; no manifest was published"
  fi

  wait "$hash_pid"
  wait "$size_pid"
  sha256="$(<"$hash_file")"
  bytes="$(<"$size_file")"
else
  dump_file="${run_dir}/database.dump"
  archive_file="${run_dir}/database.${archive_suffix}"

  pg_dump "${PG_DUMP_ARGS[@]}" > "$dump_file"
  validate_pg_archive "$dump_file"

  if encryption_enabled; then
    gpg --batch --yes --pinentry-mode loopback \
      --passphrase-file "$passphrase_file" \
      --symmetric --cipher-algo AES256 --compress-algo none \
      --output "$archive_file" "$dump_file"
    rm "$dump_file"
  else
    archive_file="$dump_file"
  fi

  sha256="$(sha256sum "$archive_file" | awk '{print $1}')"
  bytes="$(stat --format='%s' "$archive_file")"
  aws_command s3 cp "$archive_file" "$(s3_uri "$temporary_key")" \
    "${S3_TRANSFER_ARGS[@]}"
fi
temporary_uploaded="yes"

[[ "$sha256" =~ ^[a-f0-9]{64}$ ]] || die "local SHA-256 calculation failed"
[[ "$bytes" =~ ^[0-9]+$ ]] || die "local byte count calculation failed"
(( bytes > 0 )) || die "pg_dump produced an empty archive"

temporary_head="$(head_object_with_retry "$temporary_key")"
temporary_bytes="$(jq -r '.ContentLength' <<< "$temporary_head")"
[[ "$temporary_bytes" == "$bytes" ]] || die "temporary upload size mismatch expected=${bytes} actual=${temporary_bytes}"

metadata="sha256=${sha256},bytes=${bytes},manifest-schema=${MANIFEST_SCHEMA_VERSION},database=${BACKUP_NAME}"
copy_args=(--only-show-errors --metadata "$metadata" --metadata-directive REPLACE --content-type application/octet-stream)
if [[ -n "$S3_STORAGE_CLASS" ]]; then copy_args+=(--storage-class "$S3_STORAGE_CLASS"); fi
if [[ -n "$S3_SERVER_SIDE_ENCRYPTION" ]]; then copy_args+=(--sse "$S3_SERVER_SIDE_ENCRYPTION"); fi

log info "promoting verified-size temporary object key=${object_key} bytes=${bytes}"
aws_command s3 cp "$(s3_uri "$temporary_key")" "$(s3_uri "$object_key")" "${copy_args[@]}"

completed_epoch="$(date +%s)"
duration_seconds=$(( completed_epoch - started_epoch ))
manifest_file="${run_dir}/manifest.json"
image_version="$(<"/opt/postgres-backup-s3/VERSION")"

jq -n \
  --argjson schema_version "$MANIFEST_SCHEMA_VERSION" \
  --arg backup_id "$run_id" \
  --arg created_at "$(epoch_to_iso8601 "$started_epoch")" \
  --arg completed_at "$(epoch_to_iso8601 "$completed_epoch")" \
  --argjson duration_seconds "$duration_seconds" \
  --arg database "$POSTGRES_DATABASE" \
  --arg server_version "$server_version" \
  --arg pg_dump_version "$(pg_dump --version)" \
  --arg image_version "$image_version" \
  --arg object_key "$object_key" \
  --argjson object_bytes "$bytes" \
  --arg sha256 "$sha256" \
  --argjson encrypted "$(encryption_enabled && printf true || printf false)" \
  --arg cipher "$(encryption_enabled && printf AES256-GPG || printf none)" \
  --arg mode "$BACKUP_MODE" \
  --arg verification "$BACKUP_VERIFY_MODE" \
  '{
    schema_version: $schema_version,
    kind: "postgresql_logical_backup",
    backup_id: $backup_id,
    created_at: $created_at,
    completed_at: $completed_at,
    duration_seconds: $duration_seconds,
    database: {name: $database, server_version: $server_version},
    producer: {image_version: $image_version, pg_dump_version: $pg_dump_version, mode: $mode},
    object: {key: $object_key, bytes: $object_bytes, sha256: $sha256, format: "pg_dump_custom"},
    encryption: {enabled: $encrypted, cipher: $cipher},
    publication: {status: "verified", verification: $verification}
  }' > "$manifest_file"

verify_remote_backup "$manifest_file" "$BACKUP_VERIFY_MODE"

aws_command s3 cp "$manifest_file" "$(s3_uri "$manifest_key")" \
  --only-show-errors --content-type application/json --cache-control no-store
published="yes"

aws_command s3 rm "$(s3_uri "$temporary_key")" --only-show-errors
temporary_uploaded="no"
write_success_state "$manifest_key" "$completed_epoch"
run_hook backup_post "$BACKUP_POST_HOOK"

log info "backup published manifest=${manifest_key} object=${object_key} bytes=${bytes} sha256=${sha256} duration_seconds=${duration_seconds}"

if [[ -n "$BACKUP_KEEP_DAYS" ]]; then
  "${SCRIPT_DIR}/retention.sh"
fi
