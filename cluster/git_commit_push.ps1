$ErrorActionPreference = "Continue"
$repoDir = "D:\zebbingo\tools\claude-bridge"
$git = "D:\Program Files\Git\cmd\git.exe"

Write-Host "S1 repo=$repoDir"
if (-not (Test-Path (Join-Path $repoDir ".git"))) { Write-Host "FAIL no .git"; exit 1 }
Write-Host "S2"

if (-not (Test-Path $git)) { Write-Host "FAIL no git"; exit 1 }
Write-Host "S3"

$ver = & $git --version
Write-Host "S4 v=$ver e=$LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { exit 1 }

& $git -C $repoDir config user.name "Administrator"
& $git -C $repoDir config user.email "admin@zebbingo.local"
& $git -C $repoDir config core.autocrlf false
Write-Host "S5"

# Use separate output and error for status
$stOut = & $git -C $repoDir status --short
$stErr = $error[0]
Write-Host "S6 e=$LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL status"; exit 1 }
Write-Host "S7 out=[$stOut]"

& $git -C $repoDir -c core.autocrlf=false add -A
Write-Host "S8 e=$LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL add"; exit 1 }

$st2 = & $git -C $repoDir status --short
if ([string]::IsNullOrWhiteSpace($st2)) { Write-Host "S9 nothing"; exit 0 }

& $git -C $repoDir commit -m "optimize: path auto-detection for cluster scripts"
Write-Host "S10 e=$LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL commit"; exit 1 }

& $git -C $repoDir push
Write-Host "S11 e=$LASTEXITCODE"
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL push"; exit 1 }

Write-Host "S12 DONE"
e