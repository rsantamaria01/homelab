#!/usr/bin/env bash
# harden-security-ssh.sh
#
# Authorize a pubkey for root, remove all other user keys, disable password auth.
# Auto-detects Proxmox (uses /etc/pve/priv/authorized_keys, syncs cluster-wide).
# Idempotent. Safe to re-run.
#
# Usage:
#   curl -fsSL <url> | sudo SSH_PUBLIC_KEY="ssh-... user@host" bash
#   wget -qO- <url>  | sudo SSH_PUBLIC_KEY="ssh-... user@host" bash
#
# Optional:
#   KEEP_KEYS_MATCHING='root@rs-srv-[0-9]+$'   # regex of existing keys to preserve

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Must run as root (use sudo)" >&2; exit 1; }
[[ -n "${SSH_PUBLIC_KEY:-}" ]] || {
  cat >&2 <<EOF
SSH_PUBLIC_KEY env var is required.

Example:
  curl -fsSL <url> | sudo SSH_PUBLIC_KEY="ssh-ed25519 AAAA... me@laptop" bash
EOF
  exit 1
}

# Normalize + validate
SSH_PUBLIC_KEY="$(printf '%s' "$SSH_PUBLIC_KEY" | tr -d '\r' | sed 's/[[:space:]]*$//')"
[[ "$SSH_PUBLIC_KEY" =~ ^(ssh-|sk-|ecdsa-) ]] \
  || { echo "Doesn't look like a valid pubkey" >&2; exit 1; }

KEEP_KEYS_MATCHING="${KEEP_KEYS_MATCHING:-}"
SSHD_DROPIN="/etc/ssh/sshd_config.d/10-disable-root-password.conf"

# Detect Proxmox vs vanilla
if [[ -f /etc/pve/priv/authorized_keys ]]; then
  AUTH_KEYS_FILE="/etc/pve/priv/authorized_keys"
  echo "▶ Proxmox detected — using $AUTH_KEYS_FILE (syncs cluster-wide)"
else
  AUTH_KEYS_FILE="/root/.ssh/authorized_keys"
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  touch "$AUTH_KEYS_FILE"
fi

log() { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()  { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
die() { printf '  \033[1;31m✗\033[0m %s\n' "$*" >&2; exit 1; }

trap 'unset SSH_PUBLIC_KEY' EXIT

# 1. Backup
log "Backing up $AUTH_KEYS_FILE"
ts=$(date +%s)
backup="${AUTH_KEYS_FILE}.bak.$ts"
cp "$AUTH_KEYS_FILE" "$backup"
ok "backup: $backup"

# 2. Rewrite authorized_keys
log "Rewriting authorized_keys"
tmp=$(mktemp)
if [[ -n "$KEEP_KEYS_MATCHING" ]]; then
  grep -E "$KEEP_KEYS_MATCHING" "$AUTH_KEYS_FILE" > "$tmp" || true
  echo "  preserved $(wc -l < "$tmp") key(s) matching: $KEEP_KEYS_MATCHING"
fi
printf '%s\n' "$SSH_PUBLIC_KEY" >> "$tmp"
awk '!seen[$0]++' "$tmp" > "$AUTH_KEYS_FILE"
chmod 640 "$AUTH_KEYS_FILE"
rm -f "$tmp"
ok "authorized_keys updated ($(wc -l < "$AUTH_KEYS_FILE") key(s) total)"

# 3. Deploy sshd drop-in
log "Disabling password auth"
cat > "$SSHD_DROPIN" <<'CFG'
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
CFG
chmod 644 "$SSHD_DROPIN"
ok "wrote $SSHD_DROPIN"

# 4. Validate before reload
log "Validating sshd config"
sshd -t || die "sshd config invalid — NOT reloading. Inspect $SSHD_DROPIN"
ok "config valid"

# 5. Reload
log "Reloading sshd"
if systemctl is-active --quiet ssh; then
  systemctl reload ssh
elif systemctl is-active --quiet sshd; then
  systemctl reload sshd
else
  die "Neither ssh nor sshd service is active"
fi
ok "sshd reloaded"

cat <<EOF

╭──────────────────────────────────────────────────────────╮
│ Done. From a NEW terminal, verify BEFORE closing this one:
│
│   ssh -o PreferredAuthentications=password \\
│       -o PubkeyAuthentication=no root@<this-host>
│   → must show: Permission denied (publickey)
│
│   ssh root@<this-host>
│   → must still work with your key
│
│ Backup: $backup
╰──────────────────────────────────────────────────────────╯
EOF