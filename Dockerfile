ARG POSTGRES_VERSION=18
ARG PGBACKREST_BASE_IMAGE=timescale/timescaledb-ha:pg18.4-ts2.28.3
ARG SUPERCRONIC_VERSION=v0.2.48
ARG SUPERCRONIC_SHA256_AMD64=88c1b66b94c486f972fdd1a4d1f901e3e75ff04f749cddd60c5db573e3a33c6c
ARG SUPERCRONIC_SHA256_ARM64=50ae8755e04fa72812d0a1bc47a112a856811cc91cce7b6c875c378a850788bc

FROM alpine:3.22 AS scheduler

ARG TARGETARCH
ARG SUPERCRONIC_VERSION
ARG SUPERCRONIC_SHA256_AMD64
ARG SUPERCRONIC_SHA256_ARM64

RUN apk add --no-cache ca-certificates coreutils curl \
    && target_arch="${TARGETARCH:-}" \
    && if [ -z "$target_arch" ]; then \
         case "$(apk --print-arch)" in \
           x86_64) target_arch=amd64 ;; \
           aarch64) target_arch=arm64 ;; \
           *) echo "Unsupported Alpine architecture: $(apk --print-arch)" >&2; exit 1 ;; \
         esac; \
       fi \
    && case "$target_arch" in \
         amd64) supercronic_sha256="${SUPERCRONIC_SHA256_AMD64}" ;; \
         arm64) supercronic_sha256="${SUPERCRONIC_SHA256_ARM64}" ;; \
         *) echo "Unsupported architecture: ${target_arch}" >&2; exit 1 ;; \
       esac \
    && curl --fail --location --show-error \
         "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${target_arch}" \
         --output /supercronic \
    && echo "${supercronic_sha256}  /supercronic" | sha256sum --check --strict \
    && chmod 0755 /supercronic

FROM postgres:${POSTGRES_VERSION}-alpine AS logical

RUN apk add --no-cache \
      aws-cli \
      bash \
      ca-certificates \
      coreutils \
      curl \
      findutils \
      gnupg \
      jq \
      su-exec \
      tzdata \
      util-linux \
    && mkdir -p /opt/postgres-backup-s3 /state /work \
    && chown -R postgres:postgres /state /work

COPY --from=scheduler /supercronic /usr/local/bin/supercronic
COPY --chmod=0755 src/*.sh /usr/local/bin/
COPY VERSION /opt/postgres-backup-s3/VERSION

ENV POSTGRES_PORT=5432 \
    POSTGRES_MAINTENANCE_DATABASE=postgres \
    S3_REGION=us-east-1 \
    S3_PREFIX=backup \
    BACKUP_MODE=stream \
    BACKUP_VERIFY_MODE=checksum \
    BACKUP_KEEP_MINIMUM=3 \
    INCOMPLETE_KEEP_HOURS=24 \
    BACKUP_MAX_AGE_SECONDS=172800 \
    BACKUP_HEALTH_START_GRACE_SECONDS=3600 \
    BACKUP_JITTER_SECONDS=0 \
    RUN_ON_STARTUP=no \
    RESTORE_MODE=verify \
    RESTORE_CREATE_DATABASE=no \
    RESTORE_DROP_DATABASE=no \
    RESTORE_CLEAN=no \
    RESTORE_JOBS=2 \
    WORK_DIR=/work \
    STATE_DIR=/state \
    AWS_PAGER="" \
    AWS_EC2_METADATA_DISABLED=true \
    HOME=/var/lib/postgresql

WORKDIR /opt/postgres-backup-s3

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

# Physical/WAL mode deliberately inherits the operator's exact PostgreSQL and
# extension image. This keeps pgBackRest and PostgreSQL versions matched while
# the logical target above remains portable across ordinary PostgreSQL images.
FROM ${PGBACKREST_BASE_IMAGE} AS pgbackrest

USER root
COPY --from=scheduler /supercronic /usr/local/bin/supercronic
COPY --chmod=0755 src/pgbackrest-sidecar.sh /usr/local/bin/pgbackrest-sidecar.sh
COPY VERSION /opt/postgres-backup-s3/VERSION
RUN mkdir -p /opt/postgres-backup-s3 /state /var/log/pgbackrest /var/spool/pgbackrest \
    && chown -R postgres:postgres /state /var/log/pgbackrest /var/spool/pgbackrest

ENV PGBACKREST_CONFIG=/dev/null \
    PGBACKREST_STANZA=postgres \
    PGBACKREST_SPOOL_PATH=/var/spool/pgbackrest \
    STATE_DIR=/state \
    BACKUP_FULL_SCHEDULE="17 3 * * 0" \
    BACKUP_DIFF_SCHEDULE="17 3 * * 1-6" \
    BACKUP_INCR_SCHEDULE="47 0,6,12,18 * * *" \
    BACKUP_CHECK_SCHEDULE="37 2 * * *" \
    RUN_ON_STARTUP=no \
    INIT_ON_STARTUP=yes

HEALTHCHECK --interval=60s --timeout=15s --start-period=60s --retries=3 \
  CMD ["/usr/local/bin/pgbackrest-sidecar.sh", "health"]

ENTRYPOINT ["/usr/local/bin/pgbackrest-sidecar.sh"]
CMD ["daemon"]

# Preserve the historical no-target build contract and published tags.
FROM logical AS default
