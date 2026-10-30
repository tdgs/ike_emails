#!/usr/bin/env bash
#
# Sets up, or updates, the nightly database backup on the server. Run it from
# the project directory through the 1Password Environment, which holds the
# values below. It asks for the sudo password of the deploy user once, to
# install the packages and the systemd timer.
#
#     op run --environment <1password-environment-id> -- deploy/backup/setup.sh
#
#   BACKUP_R2_ACCESS_KEY_ID      R2 API token limited to the backup bucket,
#   BACKUP_R2_SECRET_ACCESS_KEY  with Object Read & Write
#   BACKUP_AGE_RECIPIENT         public key (age1...) of the key pair made with
#                                age-keygen. Keep the private key in 1Password.
#   BACKUP_PING_URL              optional, see backup.sh
set -euo pipefail

host=deploy@203.0.113.10
bucket=ike-email-backups
endpoint=https://b3558df98013686d5554e48c46b5721e.eu.r2.cloudflarestorage.com

: "${BACKUP_R2_ACCESS_KEY_ID:?}" "${BACKUP_R2_SECRET_ACCESS_KEY:?}" "${BACKUP_AGE_RECIPIENT:?}"

cd "$(dirname "$0")"

ssh "$host" 'mkdir -p ~/ike-emails-backup ~/.config'

# The values go over stdin, not as arguments, so they are not in any process list.
# The heredoc is meant to expand here, on this machine.
# shellcheck disable=SC2087
ssh "$host" 'umask 077 && cat > ~/.config/ike-emails-backup.env' <<EOF
BACKUP_BUCKET=$bucket
BACKUP_AGE_RECIPIENT=$BACKUP_AGE_RECIPIENT
BACKUP_PING_URL=${BACKUP_PING_URL:-}
RCLONE_CONFIG_R2_TYPE=s3
RCLONE_CONFIG_R2_PROVIDER=Cloudflare
RCLONE_CONFIG_R2_ENDPOINT=$endpoint
RCLONE_CONFIG_R2_ACCESS_KEY_ID=$BACKUP_R2_ACCESS_KEY_ID
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$BACKUP_R2_SECRET_ACCESS_KEY
RCLONE_CONFIG_R2_REGION=auto
# The token can't create buckets, so rclone must not try
RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
EOF

scp -q backup.sh "$host:ike-emails-backup/backup.sh"
scp -q ike-emails-backup.service ike-emails-backup.timer "$host:ike-emails-backup/"

ssh -t "$host" 'chmod 755 ~/ike-emails-backup/backup.sh &&
  sudo sh -c "apt-get install -y age rclone &&
    install -m 644 /home/deploy/ike-emails-backup/ike-emails-backup.service /home/deploy/ike-emails-backup/ike-emails-backup.timer /etc/systemd/system/ &&
    systemctl daemon-reload &&
    systemctl enable --now ike-emails-backup.timer"'

echo "Done. Run one backup now with: ssh $host 'sudo systemctl start ike-emails-backup.service'"
