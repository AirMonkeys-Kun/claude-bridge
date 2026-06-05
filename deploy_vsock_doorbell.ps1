# deploy_vsock_doorbell.ps1
# Deploys vsock doorbell daemon to VM rootfs via WSL VHDX mount
# Run from host (Windows PowerShell)

param(
    [switch]$DryRun,
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
$VhdPath = "D:\vm_bundles\claudevm.bundle\rootfs.vhdx"
$BridgeDir = "D:\zebbingo\tools\claude-bridge"

# Files to deploy
$DaemonPy = "$BridgeDir\vsock_doorbell_daemon.py"
$ServiceFile = "$BridgeDir\vsock-doorbell.service"

Write-Host "=== Vsock Doorbell Daemon Deployment ===" -ForegroundColor Cyan

# Step 1: Verify files exist
if (-not (Test-Path $DaemonPy)) { throw "Missing: $DaemonPy" }
if (-not (Test-Path $ServiceFile)) { throw "Missing: $ServiceFile" }
Write-Host "[1/6] Source files verified" -ForegroundColor Green

if ($VerifyOnly) {
    Write-Host "Files OK. Not deploying (VerifyOnly mode)."
    return
}

# Step 2: Stop VM
Write-Host "[2/6] Stopping VM..." -ForegroundColor Yellow
taskkill /f /im cowork-svc.exe 2>$null
Start-Sleep -Seconds 3
Write-Host "  VM stopped"

if ($DryRun) {
    Write-Host "[DRY RUN] Would mount VHDX, copy files, unmount, restart"
    return
}

# Step 3: Mount VHDX via WSL
Write-Host "[3/6] Mounting VHDX via WSL..." -ForegroundColor Yellow
$mountResult = wsl --mount $VhdPath --vhd 2>&1
Write-Host "  WSL mount: $mountResult"
Start-Sleep -Seconds 2

# Get the WSL mount point
$wslMount = wsl bash -c "findmnt -t ext4 -o TARGET -n 2>/dev/null | head -1"
if (-not $wslMount) {
    $wslMount = "/mnt/wsl/vhdx"
}
Write-Host "  Mount point: $wslMount"

# Step 4: Copy files into VHDX
Write-Host "[4/6] Deploying files..." -ForegroundColor Yellow

# Copy daemon
wsl bash -c "cp /mnt/d/zebbingo/tools/claude-bridge/vsock_doorbell_daemon.py /mnt/vhdx/usr/local/bin/vsock_doorbell_daemon.py"
wsl bash -c "chmod +x /mnt/vhdx/usr/local/bin/vsock_doorbell_daemon.py"

# Copy systemd service
wsl bash -c "cp /mnt/d/zebbingo/tools/claude-bridge/vsock-doorbell.service /mnt/vhdx/etc/systemd/system/vsock-doorbell.service"

# Enable service
wsl bash -c "ln -sf /etc/systemd/system/vsock-doorbell.service /mnt/vhdx/etc/systemd/system/multi-user.target.wants/vsock-doorbell.service 2>/dev/null; echo 'Service linked'"

Write-Host "  Files deployed"

# Step 5: Unmount VHDX
Write-Host "[5/6] Unmounting VHDX..." -ForegroundColor Yellow
wsl --unmount $VhdPath 2>&1
Start-Sleep -Seconds 2
Write-Host "  VHDX unmounted"

# Step 6: Restart VM
Write-Host "[6/6] Restarting VM..." -ForegroundColor Yellow
sc start CoworkVMService 2>&1
Write-Host "  VM restart initiated"

Write-Host ""
Write-Host "=== Deployment Complete ===" -ForegroundColor Green
Write-Host "The doorbell daemon will start on next VM boot."
Write-Host "Check status with: systemctl status vsock-doorbell"
