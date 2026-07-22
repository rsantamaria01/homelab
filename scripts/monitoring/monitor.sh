#!/usr/bin/env bash
# monitor.sh — onboard a Proxmox target into the telemetry stack (Loki +
# Prometheus + Grafana). Installs the right agents, then registers the target
# with Prometheus via file_sd and reloads it. Cluster-aware: run on ANY node,
# it finds where the target / Loki / Prometheus containers live and acts there
# (hopping over the root SSH link PVE already provisions between members).
#
# MODES:
#   node    this PVE host        -> node_exporter + Alloy            :9100
#   lxc     an LXC (GUEST_ID)    -> node_exporter + Alloy            :9100
#   vm      a VM  (GUEST_ID)     -> node_exporter + Alloy            :9100
#             (via qemu-guest-agent exec — agent must be running, PVE >= 7.2)
#   docker  a docker LXC host    -> node_exporter + Alloy + cAdvisor :9100,:8181
#   pve     install prometheus-pve-exporter on THIS node            :9221 /pve
#             (requires PVE_API_TOKEN)
#
# Each mode is its own Prometheus job + file_sd dir (targets/<mode>/<name>.json).
#
# Usage (everything via env — nothing after ./monitor.sh):
#   LOKI_LXC_ID=109 PROM_LXC_ID=110 MODE=node                     ./monitor.sh
#   LOKI_LXC_ID=109 PROM_LXC_ID=110 MODE=lxc    GUEST_ID=105      ./monitor.sh
#   LOKI_LXC_ID=109 PROM_LXC_ID=110 MODE=vm     GUEST_ID=201      ./monitor.sh
#   LOKI_LXC_ID=109 PROM_LXC_ID=110 MODE=docker GUEST_ID=108      ./monitor.sh
#   PROM_LXC_ID=110 MODE=pve PVE_API_TOKEN='root@pam!mon=UUID'    ./monitor.sh
#
# Variables are GATED per mode (missing required -> error; setting a blocked one
# -> error). Always: MODE, PROM_LXC_ID.
#   node          : + LOKI_LXC_ID              (blocks GUEST_ID, PVE_API_TOKEN)
#   lxc|vm|docker : + LOKI_LXC_ID, GUEST_ID    (blocks PVE_API_TOKEN)
#   pve           : + PVE_API_TOKEN            (blocks LOKI_LXC_ID, GUEST_ID)
# Optional : LOKI_URL()  LOKI_PORT(3100)  NODE_PORT(9100)  CADVISOR_PORT(8181)
#            PVE_PORT(9221)  PROM_TGT_DIR(/etc/prometheus/targets)
#            PROM_SVC(prometheus)  PROM_YML(/etc/prometheus/prometheus.yml)
#            NODE_EXPORTER_VER(1.8.2)  CADVISOR_VER(v0.49.1)  SKIP_LOGS/SKIP_METRICS
#
# On first use of a mode the script appends that mode's file_sd job to the
# Prometheus LXC's prometheus.yml (idempotent, backs up once to .bak) + reloads.

set -Eeuo pipefail

MODE="${MODE:-}"
GUEST_ID="${GUEST_ID:-}"
LOKI_LXC_ID="${LOKI_LXC_ID:-}"; PROM_LXC_ID="${PROM_LXC_ID:-}"
LOKI_PORT="${LOKI_PORT:-3100}"; NODE_PORT="${NODE_PORT:-9100}"
CADVISOR_PORT="${CADVISOR_PORT:-8181}"; PVE_PORT="${PVE_PORT:-9221}"
PROM_TGT_DIR="${PROM_TGT_DIR:-/etc/prometheus/targets}"; PROM_SVC="${PROM_SVC:-prometheus}"
PROM_YML="${PROM_YML:-/etc/prometheus/prometheus.yml}"
NODE_EXPORTER_VER="${NODE_EXPORTER_VER:-1.8.2}"; CADVISOR_VER="${CADVISOR_VER:-v0.49.1}"
SELF="$(hostname)"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)

YW="\033[33m"; GN="\033[1;92m"; RD="\033[01;31m"; BL="\033[36m"; CL="\033[m"
BFR="\r\033[K"; CM="${GN}✓${CL}"; CROSS="${RD}✗${CL}"; INFO="${BL}»${CL}"
msg_info()  { echo -ne " ${YW}⏳ ${1}...${CL}"; }
msg_ok()    { echo -e  "${BFR} ${CM} ${1}"; }
msg_error() { echo -e  "${BFR} ${CROSS} ${RD}${1}${CL}"; }
line()      { echo -e  " ${INFO} ${1}"; }
error_handler() { msg_error "line ${1}: '${BASH_COMMAND}' exited $?"; exit 1; }
trap 'error_handler $LINENO' ERR
die() { msg_error "$1"; exit 1; }

# Reject externally-derived values that could break shell/ssh reparse, the
# file_sd filename (path traversal), or the JSON labels. Hostnames and IPs are
# legitimately this charset, so the check costs nothing.
valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe target name: '$1'"; }
valid_ip()   { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unusable target IP: '$1'"; }
# extract the src IP from `ip route get` output — the default-route address,
# avoiding docker/bridge IPs (172.17.x) that can sort first in `hostname -I`.
route_ip4() { awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}'; }

# ---- validate mode + gate variables per mode ------------------------------
command -v pct >/dev/null || die "pct not found — run on a Proxmox node"
[[ -n "$MODE" ]] || die "MODE required — one of: node | lxc | vm | docker | pve"

# require: each named var must be set. forbid: each must be UNSET for this mode.
require_vars() { local v; for v in "$@"; do [[ -n "${!v:-}" ]] || die "$v required for MODE=$MODE"; done; }
forbid_vars()  { local v; for v in "$@"; do [[ -z "${!v:-}" ]] || die "$v must NOT be set for MODE=$MODE"; done; }

case "$MODE" in
  node)         require_vars PROM_LXC_ID LOKI_LXC_ID;          forbid_vars GUEST_ID PVE_API_TOKEN ;;
  lxc|vm|docker) require_vars PROM_LXC_ID LOKI_LXC_ID GUEST_ID; forbid_vars PVE_API_TOKEN
                 [[ "$GUEST_ID" =~ ^[0-9]+$ ]] || die "GUEST_ID must be numeric" ;;
  pve)          require_vars PROM_LXC_ID PVE_API_TOKEN;         forbid_vars LOKI_LXC_ID GUEST_ID ;;
  *) die "MODE must be: node | lxc | vm | docker | pve" ;;
esac

# ---- cluster helpers ------------------------------------------------------
# Locate a CT/VM id in the cluster via the shared FS. Echoes "<node> <lxc|qemu>".
ct_locate() {
  local id="$1" d n
  for d in /etc/pve/nodes/*; do
    n="$(basename "$d")"
    [[ -f "$d/lxc/$id.conf" ]]         && { echo "$n lxc";  return; }
    [[ -f "$d/qemu-server/$id.conf" ]] && { echo "$n qemu"; return; }
  done
}
# Cluster IP for a node name (node names aren't always DNS/hosts-resolvable).
# Proxmox records each member's ring address in /etc/pve/.members; fall back to
# the name itself if that lookup fails.
node_addr() {
  local n="$1" ip=""
  [[ -r /etc/pve/.members ]] && \
    ip="$(grep -A3 -F "\"$n\"" /etc/pve/.members | grep -oP '"ip"\s*:\s*"\K[0-9.]+' | head -1 || true)"
  echo "${ip:-$n}"
}
# Run a command on a node: local direct, else over PVE's inter-node SSH (by IP).
nrun() {
  local node="$1"; shift
  if [[ "$node" == "$SELF" ]]; then "$@"
  else ssh "${SSH_OPTS[@]}" "root@$(node_addr "$node")" "$@"; fi
}

echo -e "\n${GN}== monitor (${MODE}) ==${CL}\n"

# ---- resolve Loki URL (all modes except pve) ------------------------------
if [[ "$MODE" != pve ]]; then
  msg_info "Resolving Loki"
  if [[ -z "${LOKI_URL:-}" ]]; then
    read -r LN _ < <(ct_locate "$LOKI_LXC_ID") || true; : "${LN:=}"
    [[ -n "$LN" ]] || die "Loki LXC $LOKI_LXC_ID not found in cluster — set LOKI_URL"
    LOKI_URL="http://$(nrun "$LN" pct exec "$LOKI_LXC_ID" -- hostname -I | awk '{print $1}'):${LOKI_PORT}"
  fi
  msg_ok "loki ${LOKI_URL}"
fi

# ---- embedded agent installer (node_exporter + Alloy [+ cAdvisor]) --------
INSTALLER="$(cat <<'GUEST_EOF'
#!/usr/bin/env bash
set -euo pipefail
LOKI_URL="${LOKI_URL:?}"; JOB_LABEL="${JOB_LABEL:-$(hostname)}"
NODE_EXPORTER_VER="${NODE_EXPORTER_VER:-1.8.2}"
HOST_FQDN="$(hostname -f 2>/dev/null || hostname)"
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; armv7l) ARCH=armv7 ;;
  *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
esac
need() { command -v "$1" >/dev/null 2>&1; }
# bounded, retrying fetch — a slow/blackholed mirror must not hang onboarding
CURL=(curl -fsSL --connect-timeout 10 --max-time 300 --retry 3 --retry-delay 2)
APT_RETRY=(-o Acquire::Retries=3)
if ! need curl || ! need wget || ! need gpg; then
  apt-get "${APT_RETRY[@]}" update -qq
  DEBIAN_FRONTEND=noninteractive apt-get "${APT_RETRY[@]}" install -y -qq curl wget ca-certificates gnupg >/dev/null
fi
# node_exporter (metrics)
if [[ "${SKIP_METRICS:-0}" != 1 ]]; then
  echo "  - node_exporter v${NODE_EXPORTER_VER}"
  tgz="node_exporter-${NODE_EXPORTER_VER}.linux-${ARCH}"; tmp="$(mktemp -d)"
  "${CURL[@]}" "https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VER}/${tgz}.tar.gz" -o "$tmp/ne.tgz"
  tar -xzf "$tmp/ne.tgz" -C "$tmp"
  install -m0755 "$tmp/${tgz}/node_exporter" /usr/local/bin/node_exporter; rm -rf "$tmp"
  id node_exporter &>/dev/null || useradd -rs /bin/false node_exporter
  cat > /etc/systemd/system/node_exporter.service <<UNIT
[Unit]
Description=Prometheus node_exporter
After=network-online.target
Wants=network-online.target
[Service]
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter --collector.systemd --collector.processes
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
  # restart (not just enable --now) so a re-run picks up a new binary/unit
  systemctl daemon-reload; systemctl enable node_exporter >/dev/null 2>&1 || true
  systemctl restart node_exporter
fi
# cAdvisor (docker mode only)
if [[ "${DEPLOY_CADVISOR:-0}" == 1 ]]; then
  need docker || { echo "docker not found on this host" >&2; exit 1; }
  echo "  - cAdvisor container :${CADVISOR_PORT:-8181}"
  docker rm -f cadvisor >/dev/null 2>&1 || true
  docker run -d --name cadvisor --restart unless-stopped \
    -p "${CADVISOR_PORT:-8181}:8080" \
    --volume=/:/rootfs:ro --volume=/var/run:/var/run:ro --volume=/sys:/sys:ro \
    --volume=/var/lib/docker/:/var/lib/docker:ro --volume=/dev/disk/:/dev/disk:ro \
    --privileged --device=/dev/kmsg "gcr.io/cadvisor/cadvisor:${CADVISOR_VER:-v0.49.1}" >/dev/null
fi
# Alloy (logs)
if [[ "${SKIP_LOGS:-0}" != 1 ]]; then
  echo "  - Grafana Alloy -> ${LOKI_URL}"
  if ! need alloy; then
    install -d -m0755 /etc/apt/keyrings
    wget -q --timeout=15 --tries=3 -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
    echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
    apt-get "${APT_RETRY[@]}" update -qq
    DEBIAN_FRONTEND=noninteractive apt-get "${APT_RETRY[@]}" install -y -qq alloy >/dev/null
  fi
  usermod -aG systemd-journal,adm alloy 2>/dev/null || true
  DOCKER_BLOCK=""
  if [[ "${DOCKER_LOGS:-0}" == 1 ]]; then
    usermod -aG docker alloy 2>/dev/null || true
    DOCKER_BLOCK="$(cat <<DB
discovery.docker "dockerd" { host = "unix:///var/run/docker.sock" }
loki.source.docker "containers" {
  host       = "unix:///var/run/docker.sock"
  targets    = discovery.docker.dockerd.targets
  forward_to = [loki.write.default.receiver]
  labels     = { job = "${JOB_LABEL}-docker", host = "${HOST_FQDN}" }
}
DB
)"
  fi
  cat > /etc/alloy/config.alloy <<ALLOY
// Managed by monitor.sh — logs -> Loki
loki.write "default" { endpoint { url = "${LOKI_URL}/loki/api/v1/push" } }
loki.relabel "journal" {
  forward_to = []
  rule { source_labels = ["__journal__systemd_unit"], target_label = "unit" }
  rule { source_labels = ["__journal_priority_keyword"], target_label = "level" }
}
loki.source.journal "read" {
  max_age = "12h"
  relabel_rules = loki.relabel.journal.rules
  forward_to = [loki.write.default.receiver]
  labels = { job = "${JOB_LABEL}", host = "${HOST_FQDN}" }
}
local.file_match "varlogs" {
  path_targets = [{ __path__ = "/var/log/*.log", job = "${JOB_LABEL}", host = "${HOST_FQDN}" }]
}
loki.source.file "varlogs" {
  targets = local.file_match.varlogs.targets
  forward_to = [loki.write.default.receiver]
}
${DOCKER_BLOCK}
ALLOY
  systemctl daemon-reload; systemctl enable --now alloy; systemctl restart alloy
fi
GUEST_EOF
)"

# Env passed into the agent installer
agent_env() {
  echo "LOKI_URL=$LOKI_URL" "JOB_LABEL=$TARGET_NAME" "NODE_EXPORTER_VER=$NODE_EXPORTER_VER" \
       "SKIP_LOGS=${SKIP_LOGS:-0}" "SKIP_METRICS=${SKIP_METRICS:-0}" \
       "DEPLOY_CADVISOR=${DEPLOY_CADVISOR:-0}" "DOCKER_LOGS=${DOCKER_LOGS:-0}" \
       "CADVISOR_PORT=$CADVISOR_PORT" "CADVISOR_VER=$CADVISOR_VER"
}

# ===========================================================================
# MODE dispatch — set TARGET_NAME / TARGET_IP / TARGET_VMID / TARGETS[] / REG_*
# ===========================================================================
TARGETS=()

case "$MODE" in

node)
  TARGET_NAME="$SELF"; TARGET_VMID="-"
  TARGET_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | route_ip4 || true)"
  [[ -n "$TARGET_IP" ]] || TARGET_IP="$(hostname -I | awk '{print $1}')"
  line "Installing agents on ${TARGET_NAME} (live):"
  env $(agent_env) bash -c "$INSTALLER"
  msg_ok "Agents installed on ${TARGET_NAME}"
  TARGETS=("${TARGET_IP}:${NODE_PORT}")
  ;;

lxc|docker)
  read -r HOST_NODE KIND < <(ct_locate "$GUEST_ID") || true; : "${HOST_NODE:=}"
  [[ -n "$HOST_NODE" ]] || die "CT/VM $GUEST_ID not found in cluster"
  [[ "$KIND" == lxc ]] || die "$GUEST_ID is a $KIND — MODE=$MODE expects an LXC"
  TARGET_NAME="$(nrun "$HOST_NODE" pct exec "$GUEST_ID" -- hostname)"
  TARGET_IP="$(nrun "$HOST_NODE" pct exec "$GUEST_ID" -- ip -4 route get 1.1.1.1 2>/dev/null | route_ip4 || true)"
  [[ -n "$TARGET_IP" ]] || TARGET_IP="$(nrun "$HOST_NODE" pct exec "$GUEST_ID" -- hostname -I | awk '{print $1}')"
  valid_name "$TARGET_NAME"; valid_ip "$TARGET_IP"
  TARGET_VMID="$GUEST_ID"
  [[ "$MODE" == docker ]] && { DEPLOY_CADVISOR=1; DOCKER_LOGS=1; }
  line "Installing agents on ${TARGET_NAME} @ ${HOST_NODE} (live):"
  TMP="/tmp/.monitor-install.$$.sh"
  printf '%s' "$INSTALLER" | nrun "$HOST_NODE" pct exec "$GUEST_ID" -- tee "$TMP" >/dev/null
  # run install, then ALWAYS clean up the temp file even on failure (the ERR
  # trap would otherwise exit before the rm), and surface the real exit code.
  set +e
  nrun "$HOST_NODE" pct exec "$GUEST_ID" -- env $(agent_env) bash "$TMP"; irc=$?
  set -e
  nrun "$HOST_NODE" pct exec "$GUEST_ID" -- rm -f "$TMP" 2>/dev/null || true
  [[ $irc -eq 0 ]] || die "in-guest install exited $irc"
  msg_ok "Agents installed on ${TARGET_NAME}"
  TARGETS=("${TARGET_IP}:${NODE_PORT}")
  [[ "$MODE" == docker ]] && TARGETS+=("${TARGET_IP}:${CADVISOR_PORT}")
  ;;

vm)
  read -r HOST_NODE KIND < <(ct_locate "$GUEST_ID") || true; : "${HOST_NODE:=}"
  [[ -n "$HOST_NODE" ]] || die "CT/VM $GUEST_ID not found in cluster"
  [[ "$KIND" == qemu ]] || die "$GUEST_ID is a $KIND — MODE=vm expects a VM"
  # '|| true' so an empty guest-agent reply falls through to the fallback/die
  # instead of tripping the ERR trap on the bare assignment (pipefail).
  TARGET_NAME="$(nrun "$HOST_NODE" qm guest cmd "$GUEST_ID" get-host-name 2>/dev/null \
                 | grep -oP '"host-name"\s*:\s*"\K[^"]+' | head -1 || true)"
  [[ -n "$TARGET_NAME" ]] || TARGET_NAME="vm-$GUEST_ID"
  TARGET_IP="$(nrun "$HOST_NODE" qm guest cmd "$GUEST_ID" network-get-interfaces 2>/dev/null \
               | grep -oP '"ip-address"\s*:\s*"\K[0-9.]+' | grep -v '^127\.' | head -1 || true)"
  [[ -n "$TARGET_IP" ]] || die "no guest-agent IP for VM $GUEST_ID — is qemu-guest-agent running?"
  valid_name "$TARGET_NAME"; valid_ip "$TARGET_IP"
  TARGET_VMID="$GUEST_ID"
  line "Installing agents in VM ${TARGET_NAME} @ ${HOST_NODE} (via guest-agent):"
  # guest-agent exec: pipe the installer to `bash -s` inside the VM (PVE >= 7.2).
  # qm returns 0 as long as the agent RAN the command — the in-guest exit code
  # lives only in the JSON payload, so parse it or a failed install looks OK.
  GX_OUT="$(printf '%s' "$INSTALLER" | nrun "$HOST_NODE" qm guest exec "$GUEST_ID" \
              --pass-stdin 1 --timeout 600 -- env $(agent_env) bash -s 2>&1)" \
    || die "guest exec transport failed — check qemu-guest-agent + PVE >= 7.2"
  printf '%s\n' "$GX_OUT"   # surface the in-guest output (buried in the JSON)
  GX_RC="$(printf '%s' "$GX_OUT" | grep -oP '"exitcode"\s*:\s*\K-?[0-9]+' | head -1 || true)"
  [[ "$GX_RC" == 0 ]] || die "in-VM install exited ${GX_RC:-unknown} — target NOT registered"
  msg_ok "Agents installed in ${TARGET_NAME}"
  TARGETS=("${TARGET_IP}:${NODE_PORT}")
  ;;

pve)
  # parse PVE_API_TOKEN = user@realm!tokenname=SECRET
  T="$PVE_API_TOKEN"
  PVE_USER="${T%%!*}"; rest="${T#*!}"; PVE_TOKNAME="${rest%%=*}"; PVE_TOKVAL="${rest#*=}"
  [[ "$T" == *"!"* && "$T" == *"="* && "$PVE_USER" == *@* && -n "$PVE_TOKNAME" && -n "$PVE_TOKVAL" ]] \
    || die "PVE_API_TOKEN malformed — want 'user@realm!tokenname=SECRET'"
  TARGET_NAME="$SELF"; TARGET_VMID="-"
  TARGET_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | route_ip4 || true)"
  [[ -n "$TARGET_IP" ]] || TARGET_IP="$(hostname -I | awk '{print $1}')"
  line "Installing prometheus-pve-exporter on ${TARGET_NAME} (live):"
  DEBIAN_FRONTEND=noninteractive apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv >/dev/null
  python3 -m venv /opt/pve-exporter
  /opt/pve-exporter/bin/pip install -q --upgrade pip prometheus-pve-exporter >/dev/null
  install -d -m0755 /etc/prometheus
  umask 077
  cat > /etc/prometheus/pve.yml <<EOF
default:
  user: ${PVE_USER}
  token_name: "${PVE_TOKNAME}"
  token_value: "${PVE_TOKVAL}"
  verify_ssl: false
EOF
  umask 022
  cat > /etc/systemd/system/prometheus-pve-exporter.service <<UNIT
[Unit]
Description=Prometheus PVE exporter
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/opt/pve-exporter/bin/pve_exporter --config.file /etc/prometheus/pve.yml --web.listen-address :${PVE_PORT}
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
UNIT
  # restart (not just enable --now) so a pre-existing/stale exporter picks up
  # the new /opt binary, unit, and pve.yml credentials
  systemctl daemon-reload; systemctl enable prometheus-pve-exporter >/dev/null 2>&1 || true
  systemctl restart prometheus-pve-exporter
  msg_ok "pve-exporter up on :${PVE_PORT}"
  TARGETS=("${TARGET_IP}:${PVE_PORT}")
  ;;
esac

# ===========================================================================
# Register with Prometheus (file_sd) + reload
# ===========================================================================
read -r PROM_NODE _ < <(ct_locate "$PROM_LXC_ID") || true; : "${PROM_NODE:=}"
[[ -n "$PROM_NODE" ]] || die "Prometheus LXC $PROM_LXC_ID not found in cluster"
# one file_sd dir + Prometheus job per mode
REG_DIR="$PROM_TGT_DIR/$MODE"
REG_FILE="${REG_DIR}/${TARGET_NAME}.json"

# build targets JSON array
tjson=""; for t in "${TARGETS[@]}"; do tjson="${tjson:+$tjson,}\"$t\""; done
TARGET_JSON="[
  {\"targets\":[${tjson}],\"labels\":{\"vmid\":\"${TARGET_VMID}\",\"name\":\"${TARGET_NAME}\",\"guest_type\":\"${MODE}\"}}
]"

msg_info "Registering ${TARGETS[*]} with Prometheus (node ${PROM_NODE})"
nrun "$PROM_NODE" pct exec "$PROM_LXC_ID" -- mkdir -p "$REG_DIR"

# Ensure prometheus.yml has the file_sd job for this mode (idempotent). Appends
# under scrape_configs if absent — scrape_configs is the last top-level block in
# a stock config, so appending extends it. Backs up once via `cp -n`.
if ! nrun "$PROM_NODE" pct exec "$PROM_LXC_ID" -- grep -qF "targets/${MODE}/" "$PROM_YML"; then
  if [[ "$MODE" == pve ]]; then
    JOB_BLOCK=$(printf '\n  - job_name: "pve"\n    metrics_path: /pve\n    params:\n      module: [%s]\n    file_sd_configs:\n      - files: ["%s/pve/*.json"]\n        refresh_interval: 5m\n' "'default'" "$PROM_TGT_DIR")
  else
    JOB_BLOCK=$(printf '\n  - job_name: "%s"\n    file_sd_configs:\n      - files: ["%s/%s/*.json"]\n        refresh_interval: 5m\n' "$MODE" "$PROM_TGT_DIR" "$MODE")
  fi
  nrun "$PROM_NODE" pct exec "$PROM_LXC_ID" -- cp -n "$PROM_YML" "${PROM_YML}.bak" 2>/dev/null || true
  printf '%s\n' "$JOB_BLOCK" | nrun "$PROM_NODE" pct exec "$PROM_LXC_ID" -- tee -a "$PROM_YML" >/dev/null
  msg_ok "Added '${MODE}' file_sd job to prometheus.yml (backup: ${PROM_YML}.bak)"
  msg_info "Registering ${TARGETS[*]} with Prometheus (node ${PROM_NODE})"
fi

printf '%s\n' "$TARGET_JSON" | nrun "$PROM_NODE" pct exec "$PROM_LXC_ID" -- tee "$REG_FILE" >/dev/null
nrun "$PROM_NODE" pct exec "$PROM_LXC_ID" -- systemctl reload "$PROM_SVC" 2>/dev/null \
  || nrun "$PROM_NODE" pct exec "$PROM_LXC_ID" -- systemctl restart "$PROM_SVC"
msg_ok "Registered ${REG_FILE} + reloaded"

echo -e "\n${GN}✅ ${TARGET_NAME} (${TARGET_IP}) onboarded [${MODE}]${CL}"
for t in "${TARGETS[@]}"; do line "metrics : http://${t}/metrics"; done
[[ "$MODE" != pve ]] && line "logs    : Alloy -> ${LOKI_URL}"
line "remove  : pct exec ${PROM_LXC_ID} -- rm ${REG_FILE} && pct exec ${PROM_LXC_ID} -- systemctl reload ${PROM_SVC}"
