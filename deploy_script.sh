#!/bin/bash
set -e
M=/tmp/rootfs_mount
echo "=== WSL Deploy Script ==="
echo "Mount point: $M"
mkdir -p "$M"
echo "MKDIR OK"
mount -t ext4 /dev/sdd1 "$M" 2>&1 || { echo "MOUNT FAILED"; lsblk -lno NAME,TYPE; exit 1; }
echo "MOUNT OK"
df -h "$M"
echo "Root contents:"
ls "$M" | head -5
echo "Copying daemon..."
mkdir -p "$M/usr/local/bin"
cp /mnt/d/zebbingo/tools/claude-bridge/vsock_doorbell_daemon.py "$M/usr/local/bin/"
echo "CP DAEMON OK"
chmod +x "$M/usr/local/bin/vsock_doorbell_daemon.py"
echo "Copying service..."
cp /mnt/d/zebbingo/tools/claude-bridge/vsock-doorbell.service "$M/etc/systemd/system/"
echo "CP SERVICE OK"
ln -sf /etc/systemd/system/vsock-doorbell.service "$M/etc/systemd/system/multi-user.target.wants/"
echo "LN OK"
echo "=== VERIFY ==="
ls -la "$M/usr/local/bin/vsock_doorbell_daemon.py"
ls -la "$M/etc/systemd/system/vsock-doorbell.service"
ls -la "$M/etc/systemd/system/multi-user.target.wants/vsock-doorbell.service"
echo "=== UNMOUNT ==="
umount "$M"
echo "=== ALL DONE ==="
