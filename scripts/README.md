# homelab/scripts

One-liner scripts for fresh Ubuntu VM/CT setup.

---

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

## Notes

- All scripts require root or `sudo`
- Tested on Ubuntu 24.04 LTS (Proxmox VMs and LXC containers)
