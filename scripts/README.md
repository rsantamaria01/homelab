# homelab/scripts

## One-liner scripts for fresh Ubuntu VM/CT setup

## install-docker.sh

Installs Docker CE + Docker Compose plugin on fresh Ubuntu.

- Adds official Docker apt repo
- Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin`
- Adds `$SUDO_USER` to `docker` group (re-login required)

```bash
# curl
curl -fsSL https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/install-docker.sh | sudo bash
# wget (fresh containers without curl)
wget -qO- https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/install-docker.sh | sudo bash
```

---

## fix-e1000e-nic.sh

Mitigates Intel e1000e NIC hangs on Proxmox nodes.

- Sets `rx-usecs 50` interrupt coalescing
- Disables `SmartPowerDownEnable`
- Disables `tso`, `gso`, `gro`, `lro` offloads
- Regenerates initramfs

> Tested on rs-srv-02 and rs-srv-03. Reboot after running.

```bash
# curl
curl -fsSL https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/fix-e1000e-nic.sh | sudo bash
# wget (fresh containers without curl)
wget -qO- https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/fix-e1000e-nic.sh | sudo bash
```

---

## create-ubuntu-template.sh

Creates a Ubuntu 24.04 cloud-init VM template on a Proxmox node.

- Downloads the Ubuntu Noble cloud image and converts it to qcow2
- Resizes the disk to 10G
- Creates a VM (VMID 1000) with q35/OVMF, virtio-scsi, and cloud-init drive
- Converts the VM to a Proxmox template

> Run directly on the Proxmox node as root. Skips safely if VMID 1000 already exists.

```bash
# curl
curl -fsSL https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/create-ubuntu-template.sh | bash
# wget (fresh containers without curl)
wget -qO- https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/create-ubuntu-template.sh | bash
```

---

## harden-security-ssh.sh

Authorizes a single pubkey for root and disables password auth.

- Backs up existing `authorized_keys` to `*.bak.<timestamp>`
- Replaces user keys with `$SSH_PUBLIC_KEY` (cluster keys can be preserved via `KEEP_KEYS_MATCHING` regex)
- Writes `/etc/ssh/sshd_config.d/10-disable-root-password.conf`:
  - `PermitRootLogin prohibit-password`
  - `PasswordAuthentication no`
  - `KbdInteractiveAuthentication no`
- Validates with `sshd -t` before reloading
- Auto-detects Proxmox: uses `/etc/pve/priv/authorized_keys` (syncs cluster-wide), otherwise `/root/.ssh/authorized_keys`

> Verify in a NEW terminal before closing the current session. Web UI (8006) on Proxmox remains as the lockout escape hatch.

```bash
# curl
curl -fsSL https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/harden-security-ssh.sh | sudo SSH_PUBLIC_KEY="ssh-ed25519 AAAA... user@host" bash
# wget (fresh containers without curl)
wget -qO- https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/harden-security-ssh.sh | sudo SSH_PUBLIC_KEY="ssh-ed25519 AAAA... user@host" bash
# Proxmox cluster: preserve inter-node trust keys
curl -fsSL https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/harden-security-ssh.sh | sudo KEEP_KEYS_MATCHING='root@rs-srv-[0-9]+$' SSH_PUBLIC_KEY="sk-ecdsa-sha2-nistp256@openssh.com AAAA... rs@rs-lap-01" bash
```

---

## monitoring/monitor.sh

Onboards a Proxmox target into the telemetry stack (Loki + Prometheus LXCs —
passed as variables, e.g. 109 / 110). Installs the right agents, then registers
the target with Prometheus via file_sd and reloads it.

**Modes** (`MODE=`) — each mode is its own Prometheus job + file_sd dir:

| mode | target | installs | targets | job / dir |
|------|--------|----------|---------|-----------|
| `node` | this PVE host | node_exporter + Alloy | `:9100` | `node` |
| `lxc` | an LXC (`GUEST_ID`) | node_exporter + Alloy | `:9100` | `lxc` |
| `vm` | a VM (`GUEST_ID`) | node_exporter + Alloy via qemu-guest-agent | `:9100` | `vm` |
| `docker` | a docker LXC host (`GUEST_ID`) | node_exporter + Alloy + cAdvisor | `:9100`, `:8181` | `docker` |
| `pve` | this node | prometheus-pve-exporter (needs `PVE_API_TOKEN`) | `:9221 /pve` | `pve` |

- **Cluster-aware** — run on *any* node. Reads `/etc/pve` to find where the
  target / Loki / Prometheus live and acts on the right node, hopping over the
  root SSH link Proxmox already provisions between members (not per-guest keys).
- **file_sd discovery** — one job per mode reading `targets/<mode>/<name>.json`.
  `monitor.sh` drops the file and reloads; `prometheus.yml` never changes per
  target; removing = delete the file.
- **Runtime hostname** names the file, the Prometheus `name` label and the Loki
  `job` label — so metrics and logs correlate in Grafana.

> Run on a Proxmox node as root. The script self-configures Prometheus: on first
> use of a mode it appends that mode's file_sd job to the Prometheus LXC's
> `prometheus.yml` (idempotent, backs up once to `.bak`) and reloads — no manual
> edit. `scripts/monitoring/prometheus.yml` is the full reference config.
> Rollout order: `pve` and all `node`s first, then `lxc`/`vm`/`docker` guests.

Everything is passed via env — nothing goes after `./monitor.sh`.

```bash
# PVE hosts (run on each)
LOKI_LXC_ID=109 PROM_LXC_ID=110 MODE=node ./monitoring/monitor.sh
# PVE exporter (once, on one node)
PROM_LXC_ID=110 MODE=pve PVE_API_TOKEN='root@pam!mon=UUID-SECRET' ./monitoring/monitor.sh
# guests — from any node
LOKI_LXC_ID=109 PROM_LXC_ID=110 MODE=lxc    GUEST_ID=105 ./monitoring/monitor.sh
LOKI_LXC_ID=109 PROM_LXC_ID=110 MODE=vm     GUEST_ID=201 ./monitoring/monitor.sh
LOKI_LXC_ID=109 PROM_LXC_ID=110 MODE=docker GUEST_ID=108 ./monitoring/monitor.sh
# curl | bash form
LOKI_LXC_ID=109 PROM_LXC_ID=110 MODE=lxc GUEST_ID=105 \
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/rsantamaria01/homelab/main/scripts/monitoring/monitor.sh)"
```

Required: `MODE`; `PROM_LXC_ID`; `LOKI_LXC_ID` (all modes but `pve`); `GUEST_ID`
(lxc/vm/docker); `PVE_API_TOKEN` (`pve`, format `user@realm!tokenname=SECRET`).
Variables are **gated per mode** — setting one that does not apply to the chosen
mode (e.g. `GUEST_ID` with `MODE=node`, or `PVE_API_TOKEN` outside `pve`) aborts
with an error, so a leftover exported var from a previous run fails loudly.
Optional (defaults): `LOKI_URL` (auto), `LOKI_PORT` (3100), `NODE_PORT` (9100),
`CADVISOR_PORT` (8181), `PVE_PORT` (9221), `PROM_TGT_DIR`
(`/etc/prometheus/targets`), `PROM_SVC` (`prometheus`), `PROM_YML`
(`/etc/prometheus/prometheus.yml`), `CADVISOR_VER` (v0.49.1), `NODE_EXPORTER_VER`
(1.8.2), `ALLOY_VER` (latest, Alpine only), `SKIP_LOGS` / `SKIP_METRICS`.

Guests may be **Debian/Ubuntu (systemd)** or **Alpine (OpenRC)** — the installer
detects `apt`/`apk` and `systemd`/`openrc` and adapts (binary Alloy on Alpine,
file-only log scraping since Alpine has no systemd journal).

Deregister (`<PROM_LXC_ID>` = your Prometheus ct):

```bash
pct exec <PROM_LXC_ID> -- rm /etc/prometheus/targets/<mode>/<name>.json \
  && pct exec <PROM_LXC_ID> -- systemctl reload prometheus
```

> **vm** needs `qemu-guest-agent` running in the VM (PVE ≥ 7.2 for `--pass-stdin`);
> guest-agent exec is not streamed live — output prints after it finishes.
> **docker** assumes the docker host is an LXC (`pct exec`); Alloy is added to the
> `docker` group to read container logs. **pve** writes the API token to
> `/etc/prometheus/pve.yml` (mode 600) on the node you run it on.

---

## Notes

- All scripts require root or `sudo`
- Tested on Ubuntu 24.04 LTS (Proxmox VMs and LXC containers)
