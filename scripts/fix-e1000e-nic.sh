#!/usr/bin/env bash
# fix-e1000e-nic.sh — auto-fix e1000e NIC hangs on Lenovo Tiny nodes
# Idempotent. Auto-detects e1000e interfaces. Reboots only if changes made.
#
# Run as root on each Proxmox node:
#   curl -fsSL <url>/fix-e1000e.sh | sudo bash
#   or: sudo bash fix-e1000e.sh

set -euo pipefail

# --- guard rails -------------------------------------------------------------
[[ $EUID -eq 0 ]] || { echo "ERR: need root"; exit 1; }

log()  { printf '[%(%H:%M:%S)T] %s\n' -1 "$*"; }
diff_q() { ! cmp -s "$1" "$2"; }

CHANGED=0

# --- 1. detect e1000e interfaces --------------------------------------------fix-e1000e
mapfile -t IFACES < <(
  for d in /sys/class/net/*/device/driver; do
    [[ -L $d ]] || continue
    drv=$(basename "$(readlink -f "$d")")
    [[ $drv == e1000e ]] || continue
    basename "$(dirname "$(dirname "$d")")"
  done
)

if [[ ${#IFACES[@]} -eq 0 ]]; then
  log "no e1000e interfaces found — nothing to do"
  exit 0
fi
log "found e1000e interfaces: ${IFACES[*]}"

# --- 2. modprobe options -----------------------------------------------------
MODPROBE_FILE=/etc/modprobe.d/e1000e.conf
NEW_MODPROBE=$(cat <<'EOF'
# Managed by fix-e1000e.sh — disable aggressive power-saving + MSI-X
# Mitigates "Detected Hardware Unit Hang" on Intel I219-LM/V (Lenovo Tiny)
options e1000e SmartPowerDownEnable=0 IntMode=0
EOF
)

TMP=$(mktemp)
printf '%s\n' "$NEW_MODPROBE" > "$TMP"

if [[ ! -f $MODPROBE_FILE ]] || diff_q "$TMP" "$MODPROBE_FILE"; then
  install -m 0644 "$TMP" "$MODPROBE_FILE"
  log "wrote $MODPROBE_FILE"
  CHANGED=1
  NEED_INITRAMFS=1
else
  log "modprobe conf already correct"
fi
rm -f "$TMP"

# --- 3. ethtool helper script (idempotent) ----------------------------------
HELPER=/usr/local/sbin/e1000e-disable-offloads
NEW_HELPER=$(cat <<'EOF'
#!/usr/bin/env bash
# Disable hardware offloads on every e1000e interface present at boot.
# Managed by fix-e1000e.sh — do not edit.
set -u
for d in /sys/class/net/*/device/driver; do
  [[ -L $d ]] || continue
  drv=$(basename "$(readlink -f "$d")")
  [[ $drv == e1000e ]] || continue
  iface=$(basename "$(dirname "$(dirname "$d")")")
  echo "e1000e-disable-offloads: tuning $iface"
  /sbin/ethtool -K "$iface" \
    tso off gso off gro off lro off \
    tx off rx off sg off 2>&1 || true
done
EOF
)

TMP=$(mktemp)
printf '%s\n' "$NEW_HELPER" > "$TMP"
if [[ ! -f $HELPER ]] || diff_q "$TMP" "$HELPER"; then
  install -m 0755 "$TMP" "$HELPER"
  log "wrote $HELPER"
  CHANGED=1
else
  log "helper script already correct"
fi
rm -f "$TMP"

# --- 4. systemd unit ---------------------------------------------------------
UNIT=/etc/systemd/system/e1000e-offloads.service
NEW_UNIT=$(cat <<EOF
[Unit]
Description=Disable e1000e hardware offloads (NIC hang workaround)
After=network-pre.target
Wants=network-pre.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=$HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
)

TMP=$(mktemp)
printf '%s\n' "$NEW_UNIT" > "$TMP"
if [[ ! -f $UNIT ]] || diff_q "$TMP" "$UNIT"; then
  install -m 0644 "$TMP" "$UNIT"
  log "wrote $UNIT"
  systemctl daemon-reload
  CHANGED=1
fi
rm -f "$TMP"

if ! systemctl is-enabled --quiet e1000e-offloads.service; then
  systemctl enable e1000e-offloads.service
  log "enabled e1000e-offloads.service"
  CHANGED=1
fi

# --- 5. apply offload tweaks NOW (don't wait for reboot) --------------------
"$HELPER"

# --- 6. update initramfs if modprobe changed --------------------------------
if [[ ${NEED_INITRAMFS:-0} -eq 1 ]]; then
  log "updating initramfs..."
  update-initramfs -u -k all
fi

# --- 7. reboot only if something changed ------------------------------------
if [[ $CHANGED -eq 1 ]]; then
  log "changes applied — rebooting in 10s (Ctrl-C to abort)"
  sleep 10
  systemctl reboot
else
  log "no changes — node already configured. done."
fi