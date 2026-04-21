#!/usr/bin/env bash
set -euo pipefail

# fix-e1000e-nic.sh — mitigate Intel e1000e NIC hangs

NIC=$(ip link show | awk -F': ' '/^[0-9]+: (en|eth|nic)/{print $2; exit}')

if [ -z "$NIC" ]; then
  echo "ERROR: No NIC found."
  exit 1
fi

echo "NIC: $NIC"

ethtool -C "$NIC" rx-usecs 50
ethtool -K "$NIC" tso off gso off gro off lro off

echo "options e1000e SmartPowerDownEnable=0" > /etc/modprobe.d/e1000e.conf

update-initramfs -u

echo "Done. Reboot to fully apply."