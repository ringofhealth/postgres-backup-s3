#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

: "${PGBACKREST_CONFIG:=/dev/null}"
: "${PGBACKREST_STANZA:=postgres}"
: "${PGBACKREST_LOG_PATH:=/var/log/pgbackrest}"
: "${PGBACKREST_SPOOL_PATH:=/var/spool/pgbackrest}"
: "${STATE_DIR:=/state}"
: "${BACKUP_FULL_SCHEDULE:=17 3 * * 0}"
: "${BACKUP_DIFF_SCHEDULE:=17 3 * * 1-6}"
: "${BACKUP_INCR_SCHEDULE:=47 0,6,12,18 * * *}"
: "${BACKUP_CHECK_SCHEDULE:=37 2 * * *}"
: "${RUN_ON_STARTUP:=no}"
: "${INIT_ON_STARTUP:=yes}"

log() {
  printf '%s level=%s app=postgres-backup-s3 engine=pgbackrest message=%q\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2
}

die() {
  log error "$1"
  exit 1
}

enabled() {
  case "${1,,}" in
    yes|true|1) return 0 ;;
    no|false|0|'') return 1 ;;
    *) die "invalid boolean value=${1}" ;;
  esac
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

  unset "$file_name"
}

load_secrets() {
  read_secret PGBACKREST_REPO1_S3_KEY
  read_secret PGBACKREST_REPO1_S3_KEY_SECRET
}

validate_restore_target() {
  local target="${RESTORE_TARGET_PATH:-}"

  [[ -n "$target" ]] || die "RESTORE_TARGET_PATH is required"
  [[ "$target" == /* && "$target" != "/" ]] ||
    die "RESTORE_TARGET_PATH must be a non-root absolute path"
  [[ "${RESTORE_CONFIRM:-}" == "$target" ]] ||
    die "RESTORE_CONFIRM must exactly match RESTORE_TARGET_PATH"
  [[ "$target" != "${PGBACKREST_PG1_PATH:-}" ]] ||
    die "restore target must not be the source PostgreSQL data path"

  mkdir -p "$target"
  [[ -z "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
    die "restore target must be empty path=${target}"
}

prepare_paths() {
  mkdir -p "$STATE_DIR" "$PGBACKREST_SPOOL_PATH" "$PGBACKREST_LOG_PATH"

  if [[ "${1:-}" == "restore" ]]; then
    validate_restore_target
  fi
}

drop_privileges() {
  if [[ "$(id -u)" != "0" ]]; then
    return 0
  fi

  chown postgres:postgres "$STATE_DIR" "$PGBACKREST_SPOOL_PATH" "$PGBACKREST_LOG_PATH"
  if [[ "${1:-}" == "restore" ]]; then
    chown postgres:postgres "$RESTORE_TARGET_PATH"
  fi

  if command -v gosu >/dev/null 2>&1; then
    exec gosu postgres:postgres /usr/local/bin/pgbackrest-sidecar.sh "$@"
  elif command -v su-exec >/dev/null 2>&1; then
    exec su-exec postgres:postgres /usr/local/bin/pgbackrest-sidecar.sh "$@"
  fi

  die "neither gosu nor su-exec is available to drop privileges"
}

pgbackrest_command() {
  pgbackrest --config="$PGBACKREST_CONFIG" --stanza="$PGBACKREST_STANZA" "$@"
}

initialize() {
  pgbackrest_command stanza-create
  pgbackrest_command check
  date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR%/}/last-check-at"
}

backup() {
  local type="$1"
  case "$type" in
    full|diff|incr) ;;
    *) die "invalid physical backup type=${type}" ;;
  esac

  (
    if ! flock -n 9; then
      log warning "backup already running; skipping type=${type}"
      exit 0
    fi

    log info "backup starting stanza=${PGBACKREST_STANZA} type=${type}"
    pgbackrest_command --type="$type" backup
    pgbackrest_command expire
    date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR%/}/last-backup-at"
    printf '%s\n' "$type" >"${STATE_DIR%/}/last-backup-type"
    log info "backup completed stanza=${PGBACKREST_STANZA} type=${type}"
  ) 9>"${STATE_DIR%/}/backup.lock"
}

restore() {
  validate_restore_target

  local args=(--pg1-path="$RESTORE_TARGET_PATH")
  if [[ -n "${RESTORE_SET:-}" ]]; then args+=(--set="$RESTORE_SET"); fi
  if [[ -n "${RESTORE_TARGET_TIME:-}" ]]; then
    args+=(--type=time --target="$RESTORE_TARGET_TIME")
  fi

  log info "restore starting stanza=${PGBACKREST_STANZA} target=${RESTORE_TARGET_PATH}"
  pgbackrest_command "${args[@]}" restore
  date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR%/}/last-restore-at"
  log info "restore completed stanza=${PGBACKREST_STANZA} target=${RESTORE_TARGET_PATH}"
}

write_schedule() {
  local path="${STATE_DIR%/}/pgbackrest.crontab"
  {
    printf '%s /usr/local/bin/pgbackrest-sidecar.sh backup full\n' "$BACKUP_FULL_SCHEDULE"
    printf '%s /usr/local/bin/pgbackrest-sidecar.sh backup diff\n' "$BACKUP_DIFF_SCHEDULE"
    printf '%s /usr/local/bin/pgbackrest-sidecar.sh backup incr\n' "$BACKUP_INCR_SCHEDULE"
    printf '%s /usr/local/bin/pgbackrest-sidecar.sh check\n' "$BACKUP_CHECK_SCHEDULE"
  } >"$path"
  printf '%s\n' "$path"
}

health() {
  pgbackrest_command info --output=json >/dev/null
  test -f "${STATE_DIR%/}/started-at"
}

main() {
  load_secrets
  prepare_paths "$@"
  drop_privileges "$@"

  case "${1:-daemon}" in
    daemon)
      date -u +%Y-%m-%dT%H:%M:%SZ >"${STATE_DIR%/}/started-at"
      if enabled "$INIT_ON_STARTUP"; then initialize; fi
      if enabled "$RUN_ON_STARTUP"; then backup incr; fi
      exec supercronic "$(write_schedule)"
      ;;
    backup)
      backup "${2:-incr}"
      ;;
    check)
      initialize
      ;;
    info)
      pgbackrest_command info --output=json
      ;;
    verify)
      pgbackrest_command verify
      ;;
    restore)
      restore
      ;;
    health)
      health
      ;;
    *)
      die "usage: pgbackrest-sidecar.sh daemon|backup [full|diff|incr]|check|info|verify|restore|health"
      ;;
  esac
}

main "$@"
