# postgres-backup-s3

A small, generic PostgreSQL backup sidecar for Amazon S3 and compatible object
stores. Its default image publishes encrypted, manifest-backed logical dumps.
The same repository also provides an opt-in `pgbackrest` image target for
physical full/differential/incremental backups, continuous WAL archiving, and
point-in-time recovery.

The images contain matching PostgreSQL 16, 17, or 18 client tools and are
published for `linux/amd64` and `linux/arm64`.

## What v2 guarantees

Each accepted backup is a pair:

```text
backup/app_2026-08-07T03-17-00Z.dump.gpg
backup/app_2026-08-07T03-17-00Z.dump.gpg.manifest.json
```

The data object is uploaded under `.incomplete/`, checked, copied to its final
key with checksum metadata, and only then receives a manifest. Consumers must
treat the manifest—not an arbitrary `.dump` object—as the publication marker.

- `pg_dump --format=custom` provides a transactionally consistent logical dump.
- `flock` prevents overlapping backup runs in one sidecar.
- Streaming mode does not stage a second database-sized file locally.
- Optional GPG AES-256 encryption happens before bytes leave the container.
- SHA-256 and byte count are recorded in immutable manifest metadata.
- S3 listing is paginated by the AWS CLI, so latest selection is not limited to
  the first 1,000 objects.
- Restore downloads to a seekable file, verifies it, and runs
  `pg_restore --exit-on-error`.
- No database is modified until `RESTORE_MODE=database` and
  `RESTORE_CONFIRM` exactly matches the target database name.
- Retention deletes only manifest-backed backup sets and always preserves a
  configured minimum number of recent backups.
- Docker health reflects the age of the last successful publication.
- Passwords, S3 keys, and the encryption passphrase support Docker/Kubernetes
  `_FILE` secrets.

The default published PostgreSQL-version tags remain the portable logical
backup layer. Physical/WAL mode is a separate image target because it must be
built from the exact PostgreSQL/extension image used by the database.

## Quick start

```sh
cp template.env .env
mkdir -p secrets
printf '%s' 'database-password' > secrets/postgres_password
printf '%s' 'backup-passphrase' > secrets/backup_passphrase
printf '%s' 's3-key-id' > secrets/s3_access_key_id
printf '%s' 's3-secret' > secrets/s3_secret_access_key
chmod 600 secrets/*

# Set the bucket and endpoint in .env, then:
docker compose up -d --build
```

The included Compose file is an example. In production, pin the image by digest,
place the database on its own durable volume, and keep object storage in a
different failure domain.

### Backblaze B2 example

Backblaze exposes an S3-compatible endpoint. Use placeholders or secret files;
never commit real keys.

```env
S3_REGION=us-east-005
S3_ENDPOINT=https://s3.us-east-005.backblazeb2.com
S3_BUCKET=my-postgres-backups
S3_PREFIX=postgres
S3_ACCESS_KEY_ID_FILE=/run/secrets/s3_access_key_id
S3_SECRET_ACCESS_KEY_FILE=/run/secrets/s3_secret_access_key
```

## Backup operation

With no `SCHEDULE`, the container performs one backup and exits. With a cron
schedule, Supercronic runs `backup.sh` and keeps the container alive.

```yaml
environment:
  SCHEDULE: "17 3 * * *"
  RUN_ON_STARTUP: "no"
```

Use a non-round minute to avoid synchronized object-store traffic. Trigger an
ad-hoc backup with:

```sh
docker compose exec backup backup.sh
# or, with the image entrypoint:
docker run --rm --env-file .env ringofhealth/postgres-backup-s3:18 backup
```

### Backup modes

`BACKUP_MODE=stream` is the default. The dump passes through optional GPG
encryption, SHA-256/byte-count taps, and the AWS CLI without a database-sized
local file.

`BACKUP_MODE=staged` writes and validates a local custom archive before upload.
Use it when local disk is plentiful or when debugging. `KEEP_LOCAL_BACKUP=yes`
keeps the successful run directory; it is intentionally off by default.

## Physical backups and WAL with pgBackRest

Build the physical target from the exact image running PostgreSQL. That image
must already contain pgBackRest; TimescaleDB's HA image does:

```sh
docker build \
  --target pgbackrest \
  --build-arg PGBACKREST_BASE_IMAGE=timescale/timescaledb-ha:pg18.4-ts2.28.3 \
  --tag postgres-backup-s3:pgbackrest-pg18 .
```

The database and sidecar share PostgreSQL's Unix socket and pgBackRest spool.
The sidecar mounts `PGDATA` read-only. PostgreSQL's own `archive_command` uses
the same repository configuration and must include the explicit empty config
file so an image-specific default path cannot change behavior:

```text
archive_mode=on
archive_command=pgbackrest --config=/dev/null --stanza=app archive-push %p
```

Use pgBackRest's native `PGBACKREST_*` variables only for pgBackRest options.
Scheduler controls intentionally use a different namespace:

| Variable | Default | Purpose |
| --- | --- | --- |
| `BACKUP_FULL_SCHEDULE` | `17 3 * * 0` | Weekly full backup. |
| `BACKUP_DIFF_SCHEDULE` | `17 3 * * 1-6` | Daily differential backup. |
| `BACKUP_INCR_SCHEDULE` | `47 0,6,12,18 * * *` | Six-hour incremental backup. |
| `BACKUP_CHECK_SCHEDULE` | `37 2 * * *` | Daily repository/archive check. |
| `INIT_ON_STARTUP` | `yes` | Idempotently create and check the stanza before scheduling. |
| `RUN_ON_STARTUP` | `no` | Run an incremental backup when the daemon starts. |
| `STATE_DIR` | `/state` | Lock, schedule, and last-success state. |

Common commands are exposed through the same sidecar entrypoint:

```sh
docker run --rm postgres-backup-s3:pgbackrest-pg18 check
docker run --rm postgres-backup-s3:pgbackrest-pg18 backup full
docker run --rm postgres-backup-s3:pgbackrest-pg18 info
docker run --rm postgres-backup-s3:pgbackrest-pg18 verify
```

Physical restore is fail-closed. Mount a new empty data volume, set
`RESTORE_TARGET_PATH`, and set `RESTORE_CONFIRM` to the exact same absolute
path. The command refuses `/`, a non-empty directory, or the configured source
`PGBACKREST_PG1_PATH`:

```sh
docker run --rm \
  -e RESTORE_TARGET_PATH=/restore/pgdata \
  -e RESTORE_CONFIRM=/restore/pgdata \
  -v restore_data:/restore/pgdata \
  postgres-backup-s3:pgbackrest-pg18 restore
```

The physical repository should use its own `PGBACKREST_REPO1_PATH` even when
logical portability dumps share the same bucket. Repository bundling, block
incremental storage, compression, retention, and S3 transport are configured
through pgBackRest's documented `PGBACKREST_*` options.

### Verification modes

| Mode | Behavior |
| --- | --- |
| `metadata` | Verifies object length and checksum metadata after publication. |
| `checksum` | Also downloads the published bytes as a stream and compares SHA-256. This is the default. |
| `archive` | Downloads to disk, verifies SHA-256, decrypts, and validates the `pg_restore` table of contents. |

`checksum` costs one full-object read for every backup. Use `archive` for
periodic restore drills. If download cost matters, use `metadata` daily and run
an independent scheduled `verify latest archive` drill.

For streamed archives above 50 GB, set `BACKUP_EXPECTED_SIZE_BYTES` to an upper
size estimate so the AWS CLI can select a safe multipart part size.

## Inspect and verify

```sh
# Accepted backups only
docker compose exec backup list.sh

# Latest backup: full download, decrypt, and pg_restore TOC validation
docker compose exec backup verify.sh latest archive

# A timestamp or complete manifest key also works
docker compose exec backup verify.sh 2026-08-07T03-17-00Z checksum
```

`verify.sh` returns non-zero for a missing object, length mismatch, checksum
mismatch, invalid manifest, wrong prefix, decryption error, or invalid custom
archive.

## Safe restore

The default command is non-destructive:

```sh
docker compose exec backup restore.sh latest
```

It performs a full archive verification and exits. To restore into a new,
disposable database:

```sh
docker compose run --rm \
  -e RESTORE_MODE=database \
  -e RESTORE_TARGET_DATABASE=restore_drill \
  -e RESTORE_CONFIRM=restore_drill \
  -e RESTORE_CREATE_DATABASE=yes \
  backup restore latest
```

The safer production pattern is restore-new-and-switch. `RESTORE_CLEAN=yes`
enables `--clean --if-exists`; `RESTORE_DROP_DATABASE=yes` is accepted only
alongside `RESTORE_CREATE_DATABASE=yes` and the exact confirmation string.

The archive is always downloaded to `WORK_DIR` because PostgreSQL custom-format
parallel restore and selective access require a seekable file. Size the restore
volume for the encrypted object plus the decrypted archive.

### TimescaleDB hooks

The image remains PostgreSQL-generic. TimescaleDB users can provide its official
pre/post restore calls without hard-coding an extension into the sidecar:

```yaml
environment:
  RESTORE_PRE_HOOK: >-
    psql --dbname "$RESTORE_TARGET_DATABASE" --command
    "CREATE EXTENSION IF NOT EXISTS timescaledb; SELECT timescaledb_pre_restore();"
  RESTORE_POST_HOOK: >-
    psql --dbname "$RESTORE_TARGET_DATABASE" --command
    "SELECT timescaledb_post_restore();"
```

Test hooks against the exact TimescaleDB image/version you operate. Extension
versions must be compatible with the source dump.

## Retention and object-store lifecycle

`BACKUP_KEEP_DAYS=30` removes accepted backup pairs older than 30 days while
preserving at least `BACKUP_KEEP_MINIMUM` (default 3). `.incomplete/` objects
older than `INCOMPLETE_KEEP_HOURS` (default 24) are cleaned separately.

If bucket versioning is enabled, an S3 delete may create a delete marker rather
than remove prior versions. Configure the bucket's non-current-version lifecycle
policy as well. The sidecar intentionally never bulk-deletes unknown or legacy
objects.

## Configuration

### Required

| Variable | Purpose |
| --- | --- |
| `POSTGRES_HOST` | PostgreSQL hostname. |
| `POSTGRES_DATABASE` | Source database name. |
| `POSTGRES_USER` | PostgreSQL user with dump/restore privileges. |
| `POSTGRES_PASSWORD` / `_FILE` | PostgreSQL password. |
| `S3_BUCKET` | Destination bucket. |

Supply `S3_ACCESS_KEY_ID` and `S3_SECRET_ACCESS_KEY` (or `_FILE`) unless the
runtime provides an IAM/workload identity.

### Common optional settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `POSTGRES_PORT` | `5432` | Database port. |
| `POSTGRES_SSLMODE` | unset | libpq SSL mode such as `require`. |
| `POSTGRES_MAINTENANCE_DATABASE` | `postgres` | Connection used by create/drop database. |
| `S3_REGION` | `us-east-1` | S3 signing region. |
| `S3_ENDPOINT` | unset | S3-compatible endpoint URL. |
| `S3_PREFIX` | `backup` | Object key prefix. Set it to an empty string for a dedicated bucket root. |
| `S3_STORAGE_CLASS` | unset | Optional storage class. |
| `S3_SERVER_SIDE_ENCRYPTION` | unset | Optional S3 SSE value such as `AES256`. |
| `S3_HEAD_MAX_ATTEMPTS` | `8` | Maximum HEAD attempts while an uploaded or server-side-copied object becomes visible. |
| `S3_HEAD_RETRY_BASE_SECONDS` | `2` | Linear backoff base for transient post-upload 404 responses. |
| `BACKUP_NAME` | database name | Safe object-name component. |
| `PASSPHRASE` / `_FILE` | unset | Enables client-side GPG encryption. |
| `PGDUMP_EXTRA_OPTS` | unset | Whitespace-delimited additional `pg_dump` flags. |
| `BACKUP_PRE_HOOK` / `BACKUP_POST_HOOK` | unset | Operator-controlled Bash hooks. |
| `BACKUP_JITTER_SECONDS` | `0` | Random delay before a scheduled dump. |
| `BACKUP_MAX_AGE_SECONDS` | `172800` | Health-check maximum last-success age. |
| `RESTORE_JOBS` | `2` | Parallel custom-archive restore jobs. |
| `RESTORE_EXTRA_OPTS` | unset | Whitespace-delimited additional restore flags. |

Hooks and extra-option strings are trusted operator configuration, not user
input. Prefer dedicated environment variables over elaborate shell expressions.

## Secret handling

The following accept either a direct value or a file, never both:

- `POSTGRES_PASSWORD` / `POSTGRES_PASSWORD_FILE`
- `S3_ACCESS_KEY_ID` / `S3_ACCESS_KEY_ID_FILE`
- `S3_SECRET_ACCESS_KEY` / `S3_SECRET_ACCESS_KEY_FILE`
- `PASSPHRASE` / `PASSPHRASE_FILE`

No credential is written into an archive or manifest. GPG receives its
passphrase through a mode-0600 temporary file, not a command-line argument.

## Recovery policy

A backup is not proven until it restores. At minimum:

1. Run logical backups periodically for portable recovery.
2. Keep the S3 bucket in a separate provider/account from the database host.
3. Enable bucket versioning and non-current-version retention.
4. Run an automated disposable-database restore drill regularly.
5. Record the restored row/application checks, not only `pg_restore --list`.
6. Use the pgBackRest target and verify a physical restore when WAL/PITR is part
   of the recovery objective.

## Development

```sh
make lint
make test
make integration POSTGRES_VERSION=18
# Optional when Docker's internal disk is constrained:
make integration POSTGRES_VERSION=18 TEST_DATA_PARENT=/mnt/test-disk
```

CI performs encrypted S3-compatible round trips on PostgreSQL 16, 17, and 18.
The integration test seeds data, streams a backup, restores a new database,
compares a deterministic row fingerprint, exercises staged mode, proves failed
dumps publish no manifest, and proves corrupt objects are rejected.

## Migrating from v1

v1 `.dump`/`.dump.gpg` objects have no manifest and are intentionally invisible
to v2 `latest` selection. Keep the old image available for emergency legacy
restore, or validate an old archive and create/import a v2 manifest explicitly.
Do not make unverified legacy objects silently eligible for automatic restore.

The old restore command was destructive by default. v2 changes that contract on
purpose.

## Acknowledgements

This project began as a fork and restructuring of Schickling's PostgreSQL S3
backup images. v2 retains the deliberately small sidecar shape while replacing
its publication, verification, scheduling, secret, retention, and restore
boundaries.
