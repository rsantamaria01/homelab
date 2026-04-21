#!/bin/bash
set -euo pipefail

# ── CONFIG ────────────────────────────────────────────────────────────────────
VMID=1000
VM_NAME="ubuntu-2404-cloudinit"
if pvesm status | awk '{print $1}' | grep -qx "pve-nvme"; then
    VM_STORAGE="pve-nvme"
else
    VM_STORAGE="local-lvm"
fi
ISO_DIR="/var/lib/vz/template/iso"
CLOUD_IMG="noble-server-cloudimg-amd64.img"
QCOW2_IMG="ubuntu-cloudinit.qcow2"
CLOUD_IMG_URL="https://cloud-images.ubuntu.com/noble/current/${CLOUD_IMG}"
DISK_SIZE="10G"
# ─────────────────────────────────────────────────────────────────────────────

echo "[*] Node: $(hostname)"

# Guard: skip if VM already exists
if qm status "$VMID" &>/dev/null; then
    echo "[!] VM $VMID already exists. Aborting."
    exit 0
fi

# Download + prepare image
cd "$ISO_DIR"

if [ ! -f "$QCOW2_IMG" ]; then
    if [ ! -f "$CLOUD_IMG" ]; then
        echo "[*] Downloading cloud image..."
        wget -q --show-progress "$CLOUD_IMG_URL"
    fi
    echo "[*] Renaming to qcow2..."
    mv "$CLOUD_IMG" "$QCOW2_IMG"
fi

echo "[*] Resizing disk to ${DISK_SIZE}..."
qemu-img resize "$QCOW2_IMG" "$DISK_SIZE"

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
    --vga serial0 \
    --machine q35

# Import + attach disk
echo "[*] Importing disk..."
qm importdisk "$VMID" "$QCOW2_IMG" "$VM_STORAGE"

echo "[*] Attaching disk..."
qm set "$VMID" --scsihw virtio-scsi-pci --scsi0 "${VM_STORAGE}:vm-${VMID}-disk-1,discard=on"

# Cloud-init drive + boot
echo "[*] Configuring cloud-init + boot..."
qm set "$VMID" --ide2 "${VM_STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0

# Convert to template
echo "[*] Converting to template..."
qm template "$VMID"

echo "[+] Done. Template ${VMID} ready on $(hostname)."