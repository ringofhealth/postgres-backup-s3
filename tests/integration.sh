#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DATA_PARENT="${TEST_DATA_PARENT:-${TMPDIR:-/tmp}}"
mkdir -p "$TEST_DATA_PARENT"
TEST_DATA_ROOT="$(mktemp -d "${TEST_DATA_PARENT%/}/postgres-backup-s3.XXXXXX")"
export TEST_DATA_ROOT
COMPOSE=(docker compose --project-directory "$ROOT_DIR" --file "${ROOT_DIR}/compose.test.yaml")

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if (( status != 0 )); then
    echo 'integration environment status:' >&2
    "${COMPOSE[@]}" ps --all >&2 || true
    echo 'integration environment logs:' >&2
    "${COMPOSE[@]}" logs --no-color --tail 200 >&2 || true
  fi
  "${COMPOSE[@]}" down --volumes --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$TEST_DATA_ROOT"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$ROOT_DIR"
"${COMPOSE[@]}" build backup
"${COMPOSE[@]}" up --detach --wait source target minio

bucket_created=no
for _attempt in $(seq 1 30); do
  # Expansion is intentionally deferred to the container's Bash process.
  # shellcheck disable=SC2016
  if "${COMPOSE[@]}" run --rm --no-deps --entrypoint /bin/bash backup -c \
    'source /usr/local/bin/common.sh; load_s3_environment; aws_command s3api create-bucket --bucket "$S3_BUCKET" >/dev/null 2>&1 || aws_command s3api head-bucket --bucket "$S3_BUCKET"' >/dev/null 2>&1; then
    bucket_created=yes
    break
  fi
  sleep 1
done
[[ "$bucket_created" == "yes" ]] || { echo 'MinIO bucket did not become ready' >&2; exit 1; }

"${COMPOSE[@]}" exec --no-TTY source psql --username postgres --dbname source <<'SQL'
CREATE SCHEMA ledger;
CREATE TABLE ledger.entries (
  id bigint PRIMARY KEY,
  label text NOT NULL,
  payload jsonb NOT NULL,
  inserted_at timestamptz NOT NULL
);
INSERT INTO ledger.entries (id, label, payload, inserted_at)
SELECT number,
       'entry-' || number,
       jsonb_build_object('number', number, 'even', number % 2 = 0),
       '2026-01-01T00:00:00Z'::timestamptz + make_interval(secs => number)
FROM generate_series(1, 1000) AS number;
SQL

source_fingerprint="$("${COMPOSE[@]}" exec --no-TTY source psql --username postgres --dbname source --tuples-only --no-align --command \
  "SELECT count(*) || ':' || md5(string_agg(id || label || payload::text, '' ORDER BY id)) FROM ledger.entries")"

"${COMPOSE[@]}" run --rm --no-deps --entrypoint /usr/local/bin/backup.sh backup

manifest_count="$("${COMPOSE[@]}" run --rm --no-deps --entrypoint /usr/local/bin/list.sh backup | tail -n +2 | wc -l | tr -d '[:space:]')"
[[ "$manifest_count" == "1" ]] || { echo "expected one manifest, found ${manifest_count}" >&2; exit 1; }

"${COMPOSE[@]}" run --rm --no-deps \
  --env POSTGRES_HOST=target \
  --env RESTORE_MODE=database \
  --env RESTORE_TARGET_DATABASE=restored \
  --env RESTORE_CONFIRM=restored \
  --env RESTORE_CREATE_DATABASE=yes \
  --entrypoint /usr/local/bin/restore.sh \
  backup latest

target_fingerprint="$("${COMPOSE[@]}" exec --no-TTY target psql --username postgres --dbname restored --tuples-only --no-align --command \
  "SELECT count(*) || ':' || md5(string_agg(id || label || payload::text, '' ORDER BY id)) FROM ledger.entries")"
[[ "$target_fingerprint" == "$source_fingerprint" ]] || {
  echo "restored rows differ source=${source_fingerprint} target=${target_fingerprint}" >&2
  exit 1
}

"${COMPOSE[@]}" run --rm --no-deps \
  --env BACKUP_MODE=staged \
  --env BACKUP_VERIFY_MODE=archive \
  --env BACKUP_NAME=source_staged \
  --entrypoint /usr/local/bin/backup.sh \
  backup
"${COMPOSE[@]}" run --rm --no-deps \
  --env BACKUP_NAME=source_staged \
  --entrypoint /usr/local/bin/verify.sh \
  backup latest archive >/dev/null

if "${COMPOSE[@]}" run --rm --no-deps \
  --env POSTGRES_DATABASE=missing_database \
  --env BACKUP_NAME=missing_database \
  --entrypoint /usr/local/bin/backup.sh \
  backup; then
  echo 'backup unexpectedly succeeded for a missing database' >&2
  exit 1
fi

failed_manifests="$("${COMPOSE[@]}" run --rm --no-deps \
  --env POSTGRES_DATABASE=missing_database \
  --env BACKUP_NAME=missing_database \
  --entrypoint /usr/local/bin/list.sh \
  backup | tail -n +2 | wc -l | tr -d '[:space:]')"
[[ "$failed_manifests" == "0" ]] || { echo 'failed backup published a manifest' >&2; exit 1; }

# Expansion is intentionally deferred to the container's Bash process.
# shellcheck disable=SC2016
"${COMPOSE[@]}" run --rm --no-deps --entrypoint /bin/bash backup -c '
  source /usr/local/bin/common.sh
  load_restore_environment
  manifest_key="$(resolve_manifest_key latest)"
  manifest="$(aws_command s3 cp "$(s3_uri "$manifest_key")" - --only-show-errors)"
  object_key="$(jq -r .object.key <<< "$manifest")"
  printf corrupted | aws_command s3 cp - "$(s3_uri "$object_key")" --only-show-errors
'

if "${COMPOSE[@]}" run --rm --no-deps --entrypoint /usr/local/bin/verify.sh backup latest checksum; then
  echo 'verification unexpectedly accepted a corrupted object' >&2
  exit 1
fi

printf 'integration test passed postgres=%s fingerprint=%s\n' "${POSTGRES_VERSION:-18}" "$source_fingerprint"
