#!/usr/bin/env bash
#
# Nightly backup of the ike_emails Postgres database to Cloudflare R2.
#
# Runs on the server as the deploy user, started by ike-emails-backup.timer.
# The dump is encrypted with age before it leaves the server. Only the public
# key is on the server, the private key is in 1Password.
#
# To restore, on a machine with age, rclone and the Postgres 17 client tools:
#
#     rclone copyto r2:ike-email-backups/db/<name>.dump.age backup.dump.age
#     age -d -i key.txt backup.dump.age > backup.dump
#     pg_restore --clean --if-exists --no-owner -d <database> backup.dump
#
# with the rclone remote "r2" set up as in setup.sh.
set -euo pipefail

container=ike-emails-db
db_user=ike_emails
db_name=ike_emails_prod
keep_days=30

# From /home/deploy/.config/ike-emails-backup.env, written by setup.sh
: "${BACKUP_BUCKET:?}" "${BACKUP_AGE_RECIPIENT:?}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

name="$db_name-$(date -u +%Y%m%dT%H%M%SZ).dump.age"

# The dump is encrypted as it is written, so the data is never on disk in the
# clear. pipefail makes a failing pg_dump fail the script before any upload.
docker exec "$container" pg_dump -U "$db_user" -Fc "$db_name" |
  age -r "$BACKUP_AGE_RECIPIENT" -o "$tmp/$name"

rclone copyto "$tmp/$name" "r2:$BACKUP_BUCKET/db/$name"
echo "uploaded db/$name ($(stat -c %s "$tmp/$name") bytes)"

# Only after a successful upload, so if backups stop, the old ones stay
rclone delete --min-age "${keep_days}d" "r2:$BACKUP_BUCKET/db"

# Optional dead man's switch (healthchecks.io or similar): it alerts when this
# ping stops arriving, which is the only way to notice a backup that never ran
if [ -n "${BACKUP_PING_URL:-}" ]; then
  curl -fsS --retry 3 -o /dev/null "$BACKUP_PING_URL"
fi
