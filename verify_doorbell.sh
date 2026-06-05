#!/bin/bash
echo "=== Doorbell Daemon Verification ==="
echo ""

# Check if daemon is running
if systemctl is-active --quiet vsock-doorbell 2>/dev/null; then
    echo "[OK] vsock-doorbell service is running"
else
    echo "[FAIL] vsock-doorbell service not running"
    echo "  Try: systemctl start vsock-doorbell"
    echo "  Or check: journalctl -u vsock-doorbell -n 20"
fi

echo ""
echo "Checking /dev/vsock:"
ls -la /dev/vsock 2>/dev/null && echo "[OK] /dev/vsock exists" || echo "[FAIL] /dev/vsock missing"

echo ""
echo "Checking Unix socket:"
ls -la /tmp/bridge-doorbell.sock 2>/dev/null && echo "[OK] Unix socket exists" || echo "[MISS] Unix socket not created yet (daemon may need to start)"

echo ""
echo "Checking vsock listener:"
ss -lx | grep 9999 2>/dev/null && echo "[OK] vsock port 9999 listening" || echo "[MISS] vsock not listening (check daemon)"

echo ""
echo "Kernel modules:"
lsmod | grep -E "vsock|hv_sock"
