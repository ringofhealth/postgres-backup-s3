#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

readonly APP_NAME="postgres-backup-s3"
readonly MANIFEST_SCHEMA_VERSION="2"

log() {
  local level="$1"
  shift
  printf '%s level=%s app=%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$level" "$APP_NAME" "$*" >&2
}

epoch_to_iso8601() {
  local epoch="$1"
  if date -u -d "@${epoch}" +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null; then
    return 0
  fi
  date -u -r "$epoch" +'%Y-%m-%dT%H:%M:%SZ'
}

die() {
  log error "$*"
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable command=$1"
}

read_secret() {
  local name="$1"
  local file_name="${name}_FILE"
  local value="${!name:-}"
  local file="${!file_name:-}"

  if [[ -n "$value" && -n "$file" ]]; then
    die "set either ${name} or ${file_name}, not both"
  fi

  if [[ -n "$file" ]]; then
    [[ -r "$file" ]] || die "secret file is not readable variable=${file_name}"
    printf -v "$name" '%s' "$(<"$file")"
    export "${name?}"
  fi
}

require_nonempty() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "required environment variable is empty variable=${name}"
}

normalize_yes_no() {
  local name="$1"
  local value="${!name:-}"

  case "${value,,}" in
    yes|true|1) printf -v "$name" '%s' "yes" ;;
    no|false|0|'') printf -v "$name" '%s' "no" ;;
    *) die "environment variable must be yes or no variable=${name} value=${value}" ;;
  esac

  export "${name?}"
}

validate_integer() {
  local name="$1"
  local value="${!name:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || die "environment variable must be a non-negative integer variable=${name} value=${value}"
}

validate_object_component() {
  local value="$1"
  local label="$2"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die "${label} must contain only letters, numbers, dot, underscore, and dash"
}

load_s3_environment() {
  read_secret S3_ACCESS_KEY_ID
  read_secret S3_SECRET_ACCESS_KEY

  : "${S3_REGION:=us-east-1}"
  # Default only when the variable is unset. An explicitly empty prefix means
  # the dedicated bucket root, which is useful when one bucket belongs to one
  # database and avoids a redundant directory component.
  : "${S3_PREFIX=backup}"
  : "${S3_ENDPOINT:=}"
  : "${S3_STORAGE_CLASS:=}"
  : "${S3_SERVER_SIDE_ENCRYPTION:=}"
  : "${S3_HEAD_MAX_ATTEMPTS:=8}"
  : "${S3_HEAD_RETRY_BASE_SECONDS:=2}"

  require_nonempty S3_BUCKET
  validate_integer S3_HEAD_MAX_ATTEMPTS
  validate_integer S3_HEAD_RETRY_BASE_SECONDS
  (( S3_HEAD_MAX_ATTEMPTS > 0 )) || die "S3_HEAD_MAX_ATTEMPTS must be greater than zero"

  S3_PREFIX="${S3_PREFIX#/}"
  S3_PREFIX="${S3_PREFIX%/}"

  if [[ -n "${S3_ACCESS_KEY_ID:-}" ]]; then
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
  fi

  if [[ -n "${S3_SECRET_ACCESS_KEY:-}" ]]; then
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
  fi

  export AWS_DEFAULT_REGION="$S3_REGION"
  export AWS_REGION="$S3_REGION"
  export AWS_PAGER=""
  export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}"

  AWS_GLOBAL_ARGS=()
  if [[ -n "$S3_ENDPOINT" ]]; then
    AWS_GLOBAL_ARGS+=(--endpoint-url "$S3_ENDPOINT")
  fi
}

load_postgres_environment() {
  read_secret POSTGRES_PASSWORD

  : "${POSTGRES_PORT:=5432}"
  : "${POSTGRES_MAINTENANCE_DATABASE:=postgres}"

  require_nonempty POSTGRES_HOST
  require_nonempty POSTGRES_DATABASE
  require_nonempty POSTGRES_USER
  require_nonempty POSTGRES_PASSWORD
  validate_integer POSTGRES_PORT

  export PGHOST="${POSTGRES_HOST:?}"
  export PGPORT="$POSTGRES_PORT"
  export PGUSER="$POSTGRES_USER"
  export PGPASSWORD="$POSTGRES_PASSWORD"
  export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
  if [[ -n "${POSTGRES_SSLMODE:-}" ]]; then
    export PGSSLMODE="$POSTGRES_SSLMODE"
  fi
}

load_common_environment() {
  read_secret PASSPHRASE

  : "${WORK_DIR:=/work}"
  : "${STATE_DIR:=/state}"
  : "${BACKUP_NAME:=${POSTGRES_DATABASE:-database}}"

  validate_object_component "$BACKUP_NAME" "BACKUP_NAME"
  mkdir -p "$WORK_DIR" "$STATE_DIR"
}

load_backup_environment() {
  load_s3_environment
  load_postgres_environment
  load_common_environment

  : "${BACKUP_MODE:=stream}"
  : "${BACKUP_VERIFY_MODE:=checksum}"
  : "${BACKUP_KEEP_DAYS:=}"
  : "${BACKUP_KEEP_MINIMUM:=3}"
  : "${INCOMPLETE_KEEP_HOURS:=24}"
  : "${BACKUP_EXPECTED_SIZE_BYTES:=}"
  : "${BACKUP_JITTER_SECONDS:=0}"
  : "${PGDUMP_EXTRA_OPTS:=}"
  : "${BACKUP_PRE_HOOK:=}"
  : "${BACKUP_POST_HOOK:=}"
  : "${KEEP_LOCAL_BACKUP:=no}"

  case "$BACKUP_MODE" in
    stream|staged) ;;
    *) die "BACKUP_MODE must be stream or staged" ;;
  esac

  case "$BACKUP_VERIFY_MODE" in
    metadata|checksum|archive) ;;
    *) die "BACKUP_VERIFY_MODE must be metadata, checksum, or archive" ;;
  esac

  normalize_yes_no KEEP_LOCAL_BACKUP
  validate_integer BACKUP_KEEP_MINIMUM
  validate_integer INCOMPLETE_KEEP_HOURS
  validate_integer BACKUP_JITTER_SECONDS
  if [[ -n "$BACKUP_KEEP_DAYS" ]]; then validate_integer BACKUP_KEEP_DAYS; fi
  if [[ -n "$BACKUP_EXPECTED_SIZE_BYTES" ]]; then validate_integer BACKUP_EXPECTED_SIZE_BYTES; fi
}

load_restore_environment() {
  load_s3_environment
  : "${RESTORE_MODE:=verify}"

  case "$RESTORE_MODE" in
    verify)
      if [[ -z "${BACKUP_NAME:-}" && -z "${POSTGRES_DATABASE:-}" ]]; then
        die "BACKUP_NAME or POSTGRES_DATABASE is required to select a backup"
      fi
      : "${POSTGRES_DATABASE:=${BACKUP_NAME:-database}}"
      ;;
    database)
      load_postgres_environment
      ;;
    *) die "RESTORE_MODE must be verify or database" ;;
  esac

  load_common_environment
  : "${RESTORE_TARGET_DATABASE:=$POSTGRES_DATABASE}"
  : "${RESTORE_CONFIRM:=}"
  : "${RESTORE_CREATE_DATABASE:=no}"
  : "${RESTORE_DROP_DATABASE:=no}"
  : "${RESTORE_CLEAN:=no}"
  : "${RESTORE_JOBS:=2}"
  : "${RESTORE_PRE_HOOK:=}"
  : "${RESTORE_POST_HOOK:=}"
  : "${RESTORE_EXTRA_OPTS:=}"

  normalize_yes_no RESTORE_CREATE_DATABASE
  normalize_yes_no RESTORE_DROP_DATABASE
  normalize_yes_no RESTORE_CLEAN
  validate_integer RESTORE_JOBS
  (( RESTORE_JOBS > 0 )) || die "RESTORE_JOBS must be greater than zero"
}

aws_command() {
  aws "${AWS_GLOBAL_ARGS[@]}" "$@"
}

s3_uri() {
  printf 's3://%s/%s' "$S3_BUCKET" "$1"
}

prefixed_key() {
  local suffix="${1#/}"

  if [[ -n "$S3_PREFIX" ]]; then
    printf '%s/%s\n' "$S3_PREFIX" "$suffix"
  else
    printf '%s\n' "$suffix"
  fi
}

s3_transfer_args() {
  S3_TRANSFER_ARGS=(--only-show-errors)
  if [[ -n "$S3_STORAGE_CLASS" ]]; then
    S3_TRANSFER_ARGS+=(--storage-class "$S3_STORAGE_CLASS")
  fi
  if [[ -n "$S3_SERVER_SIDE_ENCRYPTION" ]]; then
    S3_TRANSFER_ARGS+=(--sse "$S3_SERVER_SIDE_ENCRYPTION")
  fi
}

run_hook() {
  local label="$1"
  local command="$2"

  [[ -n "$command" ]] || return 0
  log info "running configured hook hook=${label}"
  /bin/bash -Eeuo pipefail -c "$command"
}

write_passphrase_file() {
  local target="$1"
  [[ -n "${PASSPHRASE:-}" ]] || return 1
  umask 077
  printf '%s' "$PASSPHRASE" > "$target"
}

encryption_enabled() {
  [[ -n "${PASSPHRASE:-}" ]]
}

database_server_version() {
  psql --dbname "$POSTGRES_DATABASE" --tuples-only --no-align --command 'SHOW server_version' | tr -d '[:space:]'
}

build_pg_dump_args() {
  PG_DUMP_ARGS=(
    --format=custom
    --host "$POSTGRES_HOST"
    --port "$POSTGRES_PORT"
    --username "$POSTGRES_USER"
    --dbname "$POSTGRES_DATABASE"
  )

  if [[ -n "$PGDUMP_EXTRA_OPTS" ]]; then
    local -a extra_args=()
    IFS=' ' read -r -a extra_args <<< "$PGDUMP_EXTRA_OPTS"
    PG_DUMP_ARGS+=("${extra_args[@]}")
  fi
}

produce_archive_stream() {
  local passphrase_file="$1"

  if encryption_enabled; then
    pg_dump "${PG_DUMP_ARGS[@]}" |
      gpg --batch --yes --pinentry-mode loopback \
        --passphrase-file "$passphrase_file" \
        --symmetric --cipher-algo AES256 --compress-algo none --output -
  else
    pg_dump "${PG_DUMP_ARGS[@]}"
  fi
}

decrypt_archive() {
  local encrypted_file="$1"
  local output_file="$2"
  local passphrase_file="$3"

  gpg --batch --yes --pinentry-mode loopback \
    --passphrase-file "$passphrase_file" \
    --decrypt --output "$output_file" "$encrypted_file"
}

validate_pg_archive() {
  local archive_file="$1"
  pg_restore --list "$archive_file" >/dev/null
}

list_manifest_entries() {
  local manifest_prefix
  manifest_prefix="$(prefixed_key "${BACKUP_NAME}_")"

  aws_command s3api list-objects-v2 \
    --bucket "$S3_BUCKET" \
    --prefix "$manifest_prefix" \
    --output json |
    jq -r '.Contents[]? | select(.Key | endswith(".manifest.json")) | [.LastModified, .Key] | @tsv' |
    sort
}

resolve_manifest_key() {
  local selector="${1:-latest}"
  local key expected_prefix
  expected_prefix="$(prefixed_key "${BACKUP_NAME}_")"

  if [[ "$selector" == "latest" ]]; then
    key="$(list_manifest_entries | tail -n 1 | cut -f2-)"
  elif [[ "$selector" == *.manifest.json ]]; then
    key="${selector#s3://"${S3_BUCKET}"/}"
  else
    key="$(list_manifest_entries | awk -F '\t' -v needle="${BACKUP_NAME}_${selector}" 'index($2, needle) { print $2 }' | tail -n 1)"
  fi

  [[ -n "$key" ]] || die "no published backup manifest matched selector=${selector}"
  case "$key" in
    "${expected_prefix}"*.manifest.json) ;;
    *) die "manifest key is outside the configured database prefix key=${key}" ;;
  esac
  printf '%s\n' "$key"
}

download_manifest() {
  local key="$1"
  local target="$2"
  s3_transfer_args
  aws_command s3 cp "$(s3_uri "$key")" "$target" "${S3_TRANSFER_ARGS[@]}"
}

validate_manifest() {
  local manifest="$1"
  local schema verified database key sha bytes expected_prefix
  expected_prefix="$(prefixed_key "${BACKUP_NAME}_")"

  jq -e . "$manifest" >/dev/null || die "backup manifest is not valid JSON"
  schema="$(jq -r '.schema_version // empty' "$manifest")"
  verified="$(jq -r '.publication.status // empty' "$manifest")"
  database="$(jq -r '.database.name // empty' "$manifest")"
  key="$(jq -r '.object.key // empty' "$manifest")"
  sha="$(jq -r '.object.sha256 // empty' "$manifest")"
  bytes="$(jq -r '.object.bytes // empty' "$manifest")"

  [[ "$schema" == "$MANIFEST_SCHEMA_VERSION" ]] || die "unsupported manifest schema version=${schema}"
  [[ "$verified" == "verified" ]] || die "manifest is not a verified publication"
  [[ -n "$database" ]] || die "manifest is missing database.name"
  [[ -n "$key" ]] || die "manifest is missing object.key"
  [[ "$sha" =~ ^[a-f0-9]{64}$ ]] || die "manifest has an invalid SHA-256 digest"
  [[ "$bytes" =~ ^[0-9]+$ ]] || die "manifest has an invalid object byte count"
  case "$key" in
    "${expected_prefix}"*) ;;
    *) die "backup object is outside the configured database prefix key=${key}" ;;
  esac
}

head_and_validate_object() {
  local manifest="$1"
  local key expected_bytes expected_sha head actual_bytes metadata_sha
  key="$(jq -r '.object.key' "$manifest")"
  expected_bytes="$(jq -r '.object.bytes' "$manifest")"
  expected_sha="$(jq -r '.object.sha256' "$manifest")"

  head="$(head_object_with_retry "$key")"
  actual_bytes="$(jq -r '.ContentLength' <<< "$head")"
  metadata_sha="$(jq -r '.Metadata.sha256 // empty' <<< "$head")"

  [[ "$actual_bytes" == "$expected_bytes" ]] || die "remote object size mismatch expected=${expected_bytes} actual=${actual_bytes}"
  [[ "$metadata_sha" == "$expected_sha" ]] || die "remote object checksum metadata mismatch"
}

head_object_with_retry() {
  local key="$1"
  local attempt=1
  local delay_seconds
  local output

  while true; do
    if output="$(aws_command s3api head-object --bucket "$S3_BUCKET" --key "$key" --output json 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi

    if [[ "$output" != *"(404)"* && "$output" != *"Not Found"* && "$output" != *"NoSuchKey"* ]]; then
      printf '%s\n' "$output" >&2
      return 1
    fi

    if (( attempt >= S3_HEAD_MAX_ATTEMPTS )); then
      printf '%s\n' "$output" >&2
      return 1
    fi

    delay_seconds=$((S3_HEAD_RETRY_BASE_SECONDS * attempt))
    log warning "uploaded object is not visible yet; retrying head key=${key} attempt=${attempt} delay_seconds=${delay_seconds}"
    sleep "$delay_seconds"
    attempt=$((attempt + 1))
  done
}

stream_remote_sha256() {
  local key="$1"
  s3_transfer_args
  aws_command s3 cp "$(s3_uri "$key")" - "${S3_TRANSFER_ARGS[@]}" |
    sha256sum |
    awk '{print $1}'
}

download_and_verify_object() {
  local manifest="$1"
  local target="$2"
  local key expected_bytes expected_sha actual_bytes actual_sha
  key="$(jq -r '.object.key' "$manifest")"
  expected_bytes="$(jq -r '.object.bytes' "$manifest")"
  expected_sha="$(jq -r '.object.sha256' "$manifest")"

  s3_transfer_args
  aws_command s3 cp "$(s3_uri "$key")" "$target" "${S3_TRANSFER_ARGS[@]}"
  actual_bytes="$(stat --format='%s' "$target")"
  actual_sha="$(sha256sum "$target" | awk '{print $1}')"

  [[ "$actual_bytes" == "$expected_bytes" ]] || die "downloaded object size mismatch expected=${expected_bytes} actual=${actual_bytes}"
  [[ "$actual_sha" == "$expected_sha" ]] || die "downloaded object SHA-256 mismatch"
}

verify_archive_backup() (
  local manifest="$1"
  local run_dir archive_file dump_file passphrase_file encrypted

  run_dir="$(mktemp -d "${WORK_DIR%/}/verify.XXXXXX")"
  trap 'rm -rf "$run_dir"' EXIT INT TERM
  archive_file="${run_dir}/archive"
  dump_file="${run_dir}/archive.dump"
  passphrase_file="${run_dir}/passphrase"
  download_and_verify_object "$manifest" "$archive_file"
  encrypted="$(jq -r '.encryption.enabled' "$manifest")"
  if [[ "$encrypted" == "true" ]]; then
    encryption_enabled || die "PASSPHRASE or PASSPHRASE_FILE is required to validate this encrypted archive"
    write_passphrase_file "$passphrase_file"
    decrypt_archive "$archive_file" "$dump_file" "$passphrase_file"
  else
    dump_file="$archive_file"
  fi
  validate_pg_archive "$dump_file"
)

verify_remote_backup() {
  local manifest="$1"
  local mode="$2"
  local key expected_sha actual_sha

  validate_manifest "$manifest"
  head_and_validate_object "$manifest"

  case "$mode" in
    metadata)
      ;;
    checksum)
      key="$(jq -r '.object.key' "$manifest")"
      expected_sha="$(jq -r '.object.sha256' "$manifest")"
      actual_sha="$(stream_remote_sha256 "$key")"
      [[ "$actual_sha" == "$expected_sha" ]] || die "remote object SHA-256 mismatch"
      ;;
    archive)
      verify_archive_backup "$manifest"
      ;;
    *) die "unknown verification mode=${mode}" ;;
  esac
}

write_success_state() {
  local manifest_key="$1"
  local completed_epoch="$2"
  local target="${STATE_DIR%/}/last-success.json"
  local temporary="${target}.tmp.$$"

  jq -n \
    --arg manifest_key "$manifest_key" \
    --argjson completed_at_epoch "$completed_epoch" \
    --arg completed_at "$(epoch_to_iso8601 "$completed_epoch")" \
    '{status: "ok", manifest_key: $manifest_key, completed_at: $completed_at, completed_at_epoch: $completed_at_epoch}' \
    > "$temporary"
  mv "$temporary" "$target"
}
