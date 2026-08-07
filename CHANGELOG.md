# Changelog

## 2.0.0

- Add manifest-last, temporary-key publication.
- Add streamed backups with SHA-256 and byte-count verification.
- Make restore verification-only by default and require explicit destructive
  confirmation.
- Add `_FILE` secrets, non-overlap locking, health state, safe retention, and
  Supercronic scheduling.
- Add PostgreSQL 16–18, amd64, and arm64 builds.
- Add real PostgreSQL/MinIO backup-and-restore acceptance tests.

This release intentionally changes the restore and latest-backup contracts.
