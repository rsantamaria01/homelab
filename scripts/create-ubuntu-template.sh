#!/bin/bash
set -euo pipefail

# ── CONFIG ────────────────────────────────────────────────────────────────────
VMID=1000
VM_NAME="ubuntu-2404-cloudinit"
VM_STORAGE="local-lvm"
ISO_DIR="/var/lib/vz/template/iso"
CLOUD_IMG="noble-server-cloudimg-amd64.img"
QCOW2_IMG="ubuntu-cloudinit.qcow2"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/${CLOUD_IMG}"
DISK_SIZE="10G"
# ─────────────────────────────────────────────────────────────────────────────

echo "[*] Node: $(hostname)"

if ! command -v virt-customize &>/dev/null; then
    echo "[*] Installing libguestfs-tools..."
    apt-get install -y libguestfs-tools
fi

# Guard: skip if VM already exists
if qm status "$VMID" &>/dev/null; then
    echo "[!] VM $VMID already exists. Aborting."
    exit 0
fi

# Download + prepare image
cd "$ISO_DIR"

if [ -f "$QCOW2_IMG" ]; then
    echo "[*] Removing existing $QCOW2_IMG..."
    rm -f "$QCOW2_IMG"
fi

if [ ! -f "$CLOUD_IMG" ]; then
    echo "[*] Downloading cloud image..."
    wget -q --show-progress "$CLOUD_IMG_URL"
fi

echo "[*] Copying to qcow2 (preserving base image for re-runs)..."
cp "$CLOUD_IMG" "$QCOW2_IMG"


echo "[*] Resizing disk to ${DISK_SIZE}..."
EXPANDED_IMG="ubuntu-cloudinit-expanded.qcow2"
qemu-img create -f qcow2 "$EXPANDED_IMG" "$DISK_SIZE"
# virt-resize expands both the partition and filesystem, unlike qemu-img resize
virt-resize --expand /dev/sda1 "$QCOW2_IMG" "$EXPANDED_IMG"
mv "$EXPANDED_IMG" "$QCOW2_IMG"

echo "[*] Installing packages into image..."
virt-customize -a "$QCOW2_IMG" \
    --run-command 'apt-get update' \
    --run-command 'apt-get install -y qemu-guest-agent' \
    --run-command 'systemctl enable qemu-guest-agent' \
    --run-command 'apt-get install -y ca-certificates curl' \
    --run-command 'install -m 0755 -d /etc/apt/keyrings' \
    --run-command 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc' \
    --run-command 'chmod a+r /etc/apt/keyrings/docker.asc' \
    --run-command 'echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable" > /etc/apt/sources.list.d/docker.list' \
    --run-command 'apt-get update' \
    --run-command 'DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'

# Create VM
echo "[*] Creating VM ${VMID}..."
qm create "$VMID" \
    --name "$VM_NAME" \
    --memory 2048 \
    --cores 2 \
    --cpu x86-64-v2-AES \
    --bios ovmf \
    --machine q35 \
    --efidisk0 "${VM_STORAGE}:0,efitype=4m,pre-enrolled-keys=1" \
    --net0 "virtio,bridge=vmbr0,firewall=1" \
    --agent enabled=1 \
    --serial0 socket \
    --vga virtio

# Import + attach disk
echo "[*] Importing disk..."
qm importdisk "$VMID" "$QCOW2_IMG" "$VM_STORAGE"

echo "[*] Attaching disk..."
DISK_REF=$(qm config "$VMID" | awk -F': ' '/^unused/{print $2; exit}')
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "${DISK_REF},discard=on"

# Cloud-init drive + boot
echo "[*] Configuring cloud-init + boot..."
qm set "$VMID" --ide2 "${VM_STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0

# Convert to template
echo "[*] Converting to template..."
qm template "$VMID"

echo "[+] Done. Template ${VMID} ready on $(hostname)."