#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=src/common.sh
source "${ROOT_DIR}/src/common.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "${label}: expected=${expected} actual=${actual}"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT INT TERM

printf 'file-secret\n' > "${tmp}/secret"
unset UNIT_SECRET || true
export UNIT_SECRET_FILE="${tmp}/secret"
read_secret UNIT_SECRET
assert_equal file-secret "$UNIT_SECRET" "_FILE secret resolution"
unset UNIT_SECRET UNIT_SECRET_FILE

validate_object_component 'db-name_1.2' test
if (validate_object_component 'unsafe/name' test) 2>/dev/null; then
  fail "unsafe object component was accepted"
fi

S3_BUCKET=test-bucket
S3_PREFIX=backups
BACKUP_NAME=app
list_manifest_entries() {
  printf '%s\t%s\n' \
    '2026-01-01T00:00:00Z' 'backups/app_2026-01-01T00-00-00Z.dump.manifest.json' \
    '2026-01-02T00:00:00Z' 'backups/app_2026-01-02T00-00-00Z.dump.manifest.json'
}
assert_equal \
  'backups/app_2026-01-02T00-00-00Z.dump.manifest.json' \
  "$(resolve_manifest_key latest)" \
  "latest manifest selection"

cat > "${tmp}/manifest.json" <<'JSON'
{
  "schema_version": 2,
  "database": {"name": "app"},
  "object": {
    "key": "backups/app_2026-01-02T00-00-00Z.dump",
    "bytes": 123,
    "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  },
  "encryption": {"enabled": false},
  "publication": {"status": "verified"}
}
JSON
validate_manifest "${tmp}/manifest.json"

S3_PREFIX=
assert_equal 'app_2026-01-02T00-00-00Z.dump' "$(prefixed_key 'app_2026-01-02T00-00-00Z.dump')" "bucket-root key construction"

list_manifest_entries() {
  printf '%s\t%s\n' \
    '2026-01-01T00:00:00Z' 'app_2026-01-01T00-00-00Z.dump.manifest.json' \
    '2026-01-02T00:00:00Z' 'app_2026-01-02T00-00-00Z.dump.manifest.json'
}
assert_equal 'app_2026-01-02T00-00-00Z.dump.manifest.json' "$(resolve_manifest_key latest)" "bucket-root manifest selection"

sed 's#backups/app_#app_#' "${tmp}/manifest.json" > "${tmp}/root-manifest.json"
validate_manifest "${tmp}/root-manifest.json"

head_attempt_file="${tmp}/head-attempts"
printf '0\n' > "$head_attempt_file"
aws_command() {
  local attempt
  attempt="$(<"$head_attempt_file")"
  attempt=$((attempt + 1))
  printf '%s\n' "$attempt" > "$head_attempt_file"

  if (( attempt < 3 )); then
    printf 'An error occurred (404) when calling HeadObject: Not Found\n' >&2
    return 1
  fi

  printf '{"ContentLength":123,"Metadata":{"sha256":"%s"}}\n' \
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
}
sleep() { :; }
S3_HEAD_MAX_ATTEMPTS=4
S3_HEAD_RETRY_BASE_SECONDS=1
head_result="$(head_object_with_retry 'backups/app.dump')"
assert_equal '3' "$(<"$head_attempt_file")" "eventually-consistent HEAD retry count"
assert_equal '123' "$(jq -r '.ContentLength' <<< "$head_result")" "eventually-consistent HEAD result"

STATE_DIR="${tmp}/state"
mkdir -p "$STATE_DIR"
completed="$(date +%s)"
write_success_state 'backups/app.manifest.json' "$completed"
BACKUP_MAX_AGE_SECONDS=60 BACKUP_HEALTH_START_GRACE_SECONDS=60 STATE_DIR="$STATE_DIR" \
  bash "${ROOT_DIR}/src/healthcheck.sh"

printf 'unit tests passed\n'
