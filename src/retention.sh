#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/common.sh
source "${SCRIPT_DIR}/common.sh"

load_s3_environment
: "${POSTGRES_DATABASE:=database}"
: "${BACKUP_NAME:=$POSTGRES_DATABASE}"
: "${BACKUP_KEEP_DAYS:=}"
: "${BACKUP_KEEP_MINIMUM:=3}"
: "${INCOMPLETE_KEEP_HOURS:=24}"
validate_object_component "$BACKUP_NAME" "BACKUP_NAME"
validate_integer BACKUP_KEEP_MINIMUM
validate_integer INCOMPLETE_KEEP_HOURS
require_command aws
require_command jq

backup_prefix="$(prefixed_key "${BACKUP_NAME}_")"
incomplete_prefix="$(prefixed_key ".incomplete/${BACKUP_NAME}_")"

if [[ -n "$BACKUP_KEEP_DAYS" ]]; then
  validate_integer BACKUP_KEEP_DAYS
  cutoff_epoch=$(( $(date +%s) - BACKUP_KEEP_DAYS * 86400 ))
  mapfile -t entries < <(list_manifest_entries)
  total="${#entries[@]}"
  deletable_count=$(( total > BACKUP_KEEP_MINIMUM ? total - BACKUP_KEEP_MINIMUM : 0 ))

  for (( index=0; index < deletable_count; index++ )); do
    last_modified="${entries[$index]%%$'\t'*}"
    manifest_key="${entries[$index]#*$'\t'}"
    modified_epoch="$(date --date="$last_modified" +%s)"
    (( modified_epoch < cutoff_epoch )) || continue

    manifest_json="$(aws_command s3 cp "$(s3_uri "$manifest_key")" - --only-show-errors)"
    object_key="$(jq -r '.object.key // empty' <<< "$manifest_json")"
    case "$object_key" in
      "${backup_prefix}"*) ;;
      *) die "retention refused object outside configured prefix key=${object_key}" ;;
    esac

    log info "removing expired verified backup manifest=${manifest_key} object=${object_key}"
    aws_command s3 rm "$(s3_uri "$object_key")" --only-show-errors
    aws_command s3 rm "$(s3_uri "$manifest_key")" --only-show-errors
  done
fi

incomplete_cutoff=$(( $(date +%s) - INCOMPLETE_KEEP_HOURS * 3600 ))
aws_command s3api list-objects-v2 \
  --bucket "$S3_BUCKET" \
  --prefix "$incomplete_prefix" \
  --output json |
  jq -r '.Contents[]? | [.LastModified, .Key] | @tsv' |
  while IFS=$'\t' read -r last_modified key; do
    [[ -n "$key" ]] || continue
    modified_epoch="$(date --date="$last_modified" +%s)"
    if (( modified_epoch < incomplete_cutoff )); then
      log warning "removing abandoned incomplete upload key=${key}"
      aws_command s3 rm "$(s3_uri "$key")" --only-show-errors
    fi
  done
