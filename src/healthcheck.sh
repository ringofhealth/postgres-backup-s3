#!/usr/bin/env bash

set -Eeuo pipefail

: "${STATE_DIR:=/state}"
: "${BACKUP_MAX_AGE_SECONDS:=172800}"
: "${BACKUP_HEALTH_START_GRACE_SECONDS:=3600}"

state_file="${STATE_DIR%/}/last-success.json"
started_file="${STATE_DIR%/}/started-at"
now="$(date +%s)"

if [[ -r "$state_file" ]]; then
  completed="$(jq -r '.completed_at_epoch // 0' "$state_file")"
  [[ "$completed" =~ ^[0-9]+$ ]] || exit 1
  (( now - completed <= BACKUP_MAX_AGE_SECONDS )) || exit 1
  exit 0
fi

if [[ -r "$started_file" ]]; then
  started="$(<"$started_file")"
  [[ "$started" =~ ^[0-9]+$ ]] || exit 1
  (( now - started <= BACKUP_HEALTH_START_GRACE_SECONDS )) || exit 1
  exit 0
fi

exit 1
