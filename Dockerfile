ARG POSTGRES_VERSION=18
FROM postgres:${POSTGRES_VERSION}-alpine

ARG TARGETARCH=amd64
ARG SUPERCRONIC_VERSION=v0.2.48
ARG SUPERCRONIC_SHA256_AMD64=88c1b66b94c486f972fdd1a4d1f901e3e75ff04f749cddd60c5db573e3a33c6c
ARG SUPERCRONIC_SHA256_ARM64=50ae8755e04fa72812d0a1bc47a112a856811cc91cce7b6c875c378a850788bc

RUN apk add --no-cache \
      aws-cli \
      bash \
      ca-certificates \
      coreutils \
      curl \
      findutils \
      gnupg \
      jq \
      tzdata \
      util-linux \
    && case "${TARGETARCH}" in \
         amd64) supercronic_sha256="${SUPERCRONIC_SHA256_AMD64}" ;; \
         arm64) supercronic_sha256="${SUPERCRONIC_SHA256_ARM64}" ;; \
         *) echo "Unsupported architecture: ${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && curl --fail --location --show-error \
         "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}" \
         --output /usr/local/bin/supercronic \
    && echo "${supercronic_sha256}  /usr/local/bin/supercronic" | sha256sum --check --strict \
    && chmod 0755 /usr/local/bin/supercronic \
    && mkdir -p /opt/postgres-backup-s3 /state /work \
    && chown -R postgres:postgres /state /work

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
USER postgres

HEALTHCHECK --interval=60s --timeout=10s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/run.sh"]
