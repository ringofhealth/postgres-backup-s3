#!/usr/bin/env bash

set -Eeuo pipefail

case "${1:-run}" in
  backup)
    shift
    exec /usr/local/bin/backup.sh "$@"
    ;;
  restore)
    shift
    exec /usr/local/bin/restore.sh "$@"
    ;;
  verify)
    shift
    exec /usr/local/bin/verify.sh "$@"
    ;;
  list)
    shift
    exec /usr/local/bin/list.sh "$@"
    ;;
  retention)
    shift
    exec /usr/local/bin/retention.sh "$@"
    ;;
  run)
    ;;
  *)
    exec "$@"
    ;;
esac

: "${STATE_DIR:=/state}"
: "${RUN_ON_STARTUP:=no}"
mkdir -p "$STATE_DIR"
date +%s > "${STATE_DIR%/}/started-at"

case "${RUN_ON_STARTUP,,}" in
  yes|true|1) /usr/local/bin/backup.sh ;;
  no|false|0|'') ;;
  *) echo "RUN_ON_STARTUP must be yes or no" >&2; exit 1 ;;
esac

if [[ -z "${SCHEDULE:-}" ]]; then
  exec /usr/local/bin/backup.sh
fi

crontab_file="${STATE_DIR%/}/backup.crontab"
printf '%s /usr/local/bin/backup.sh\n' "$SCHEDULE" > "$crontab_file"
exec /usr/local/bin/supercronic "$crontab_file"
