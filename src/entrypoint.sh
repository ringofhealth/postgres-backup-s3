#!/usr/bin/env sh

set -eu

: "${WORK_DIR:=/work}"
: "${STATE_DIR:=/state}"

if [ "$(id -u)" = "0" ]; then
  mkdir -p "$WORK_DIR" "$STATE_DIR"
  chown postgres:postgres "$WORK_DIR" "$STATE_DIR"
  exec su-exec postgres:postgres /usr/local/bin/run.sh "$@"
fi

exec /usr/local/bin/run.sh "$@"
