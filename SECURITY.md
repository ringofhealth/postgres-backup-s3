# Security policy

Please report vulnerabilities privately through GitHub Security Advisories for
this repository. Do not open a public issue containing credentials, bucket
names, database dumps, or exploit details.

The image never needs a public database port. Place it on the database's private
container network and grant its S3 identity access only to the configured backup
prefix. Use read/write/delete for scheduled backup and retention; a verifier can
use a separate read-only identity.

Never commit `.env`, Docker secret files, GPG passphrases, database passwords, or
cloud keys. Rotate credentials immediately if they appear in logs, chat, shell
history, an image layer, or Git history.
