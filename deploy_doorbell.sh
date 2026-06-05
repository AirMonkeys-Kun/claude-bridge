#!/bin/bash
# Run INSIDE the VM (outside sandbox) after VHDX mount
set -e

cp /mnt/host/vsock_doorbell_daemon.py /usr/local/bin/vsock_doorbell_daemon.py
chmod +x /usr/local/bin/vsock_doorbell_daemon.py
cp /mnt/host/vsock-doorbell.service /etc/systemd/system/vsock-doorbell.service
systemctl daemon-reload
systemctl enable vsock-doorbell
echo "Doorbell daemon deployed successfully"
