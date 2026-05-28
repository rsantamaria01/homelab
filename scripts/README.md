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

## Notes

- All scripts require root or `sudo`
- Tested on Ubuntu 24.04 LTS (Proxmox VMs and LXC containers)
