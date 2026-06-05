<#
.SYNOPSIS
    Deploy vsock doorbell daemon to Claude VM rootfs via WSL VHDX mount.
    This script runs autonomously - it stops the VM, deploys, and restarts.

.DESCRIPTION
    The doorbell daemon bridges Hyper-V vsock signals to a Unix socket
    inside the bwrap sandbox, eliminating ~200-600ms FUSE attribute cache delay
    for file change detection. File I/O is fast (0-3ms), but file DETECTION
    is slow due to FUSE entry_timeout=1s. The doorbell provides instant notification.
#>

param([switch]$DryRun)

$ErrorActionPreference = "Continue"
$VhdPath = "D:\vm_bundles\claudevm.bundle\rootfs.vhdx"
$BridgeDir = "D:\zebbingo\tools\claude-bridge"
$LogFile = "$BridgeDir\deploy_doorbell.log"

function Write-Log($msg) {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$ts $msg" | Out-File -Append $LogFile
    Write-Host "$ts $msg"
}

Write-Log "=== Vsock Doorbell Daemon Deployment ==="
Write-Log "VHDX: $VhdPath"

# Step 1: Verify source files
$files = @(
    "$BridgeDir\vsock_doorbell_daemon.py",
    "$BridgeDir\vsock-doorbell.service"
)
foreach ($f in $files) {
    if (-not (Test-Path $f)) { 
        Write-Log "ERROR: Missing $f"
        exit 1
    }
    Write-Log "OK: $f ($((Get-Item $f).Length) bytes)"
}

if ($DryRun) {
    Write-Log "DRY RUN - would deploy but skipping actual operations"
    exit 0
}

# Step 2: Stop VM
Write-Log "Stopping VM (cowork-svc)..."
taskkill /f /im cowork-svc.exe 2>&1 | Out-Null
$retry = 0
while ((Get-Process cowork-svc -ErrorAction SilentlyContinue).Count -gt 0 -and $retry -lt 5) {
    Start-Sleep -Seconds 1
    $retry++
}
Start-Sleep -Seconds 3
Write-Log "VM stopped (waited $((3+$retry))s)"

# Step 3: Check if VHDX is unlocked
Write-Log "Checking VHDX lock..."
try {
    $fs = [System.IO.File]::Open($VhdPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    $fs.Close()
    Write-Log "VHDX is unlocked"
} catch {
    Write-Log "VHDX still locked, waiting 5s..."
    Start-Sleep -Seconds 5
}

# Step 4: Mount via WSL
Write-Log "Mounting VHDX via WSL..."
$wslResult = wsl --mount $VhdPath --vhd 2>&1
Write-Log "WSL mount result: $wslResult"
Start-Sleep -Seconds 2

# Verify mount
$mountCheck = wsl bash -c "lsblk -o NAME,MOUNTPOINT 2>/dev/null | grep -v loop" 2>&1
Write-Log "Block devices: $mountCheck"

# Find mount point
$wslMount = wsl bash -c "findmnt -t ext4 -o TARGET -n 2>/dev/null | head -1" 2>&1
if (-not $wslMount -or $wslMount -eq "") {
    # Try common paths
    $wslMount = wsl bash -c "ls -d /mnt/wsl/*/ 2>/dev/null | head -1" 2>&1
}
if (-not $wslMount -or $wslMount -eq "") {
    Write-Log "ERROR: Could not find WSL mount point"
    Write-Log "Attempting VM restart anyway..."
    sc start CoworkVMService 2>&1 | Out-Null
    exit 1
}
Write-Log "WSL mount point: $wslMount"

# Step 5: Deploy files
Write-Log "Deploying daemon to $wslMount..."
$deployCmd = @"
echo "=== Deploying doorbell daemon ==="
ls -la /mnt/d/zebbingo/tools/claude-bridge/vsock_doorbell_daemon.py
cp /mnt/d/zebbingo/tools/claude-bridge/vsock_doorbell_daemon.py $wslMount/tmp/vsock_doorbell_daemon.py
chmod +x $wslMount/tmp/vsock_doorbell_daemon.py
cp /mnt/d/zebbingo/tools/claude-bridge/vsock-doorbell.service $wslMount/etc/systemd/system/vsock-doorbell.service
ln -sf /etc/systemd/system/vsock-doorbell.service $wslMount/etc/systemd/system/multi-user.target.wants/vsock-doorbell.service 2>/dev/null
echo "Daemon:"
ls -la $wslMount/tmp/vsock_doorbell_daemon.py
echo "Service:"
ls -la $wslMount/etc/systemd/system/vsock-doorbell.service
echo "Deploy done"
"@

$deployResult = wsl bash -c $deployCmd 2>&1
Write-Log "Deploy result: $deployResult"

# Step 6: Unmount VHDX
Write-Log "Unmounting VHDX..."
wsl --unmount $VhdPath 2>&1 | Out-Null
Start-Sleep -Seconds 2
Write-Log "VHDX unmounted"

# Step 7: Restart VM
Write-Log "Restarting VM..."
sc start CoworkVMService 2>&1 | Out-Null
Write-Log "VM restart initiated"

Write-Log "=== Deployment complete ==="
Write-Log "Next steps: wait for VM to boot, then verify with:"
Write-Log "  systemctl status vsock-doorbell"
Write-Log "  ls -la /tmp/bridge-doorbell.sock"
