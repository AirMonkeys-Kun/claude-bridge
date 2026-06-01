#Requires -Version 5.0
<#
.SYNOPSIS
  Locate git.exe on this Windows system using multiple strategies.
.DESCRIPTION
  Searches PATH (via Get-Command), common install locations, and
  the registry.  Outputs the first real (non-WSL) git.exe found.
#>
$ErrorActionPreference = "Continue"

$found = $null

# ── 1. PATH lookup via Get-Command ──────────────────────────────
try {
    $cmd = Get-Command git.exe -ErrorAction Stop
    if ($cmd.Source -and (Test-Path $cmd.Source)) {
        $found = $cmd.Source
        Write-Host "Found via Get-Command: $found"
    }
} catch { Write-Host "Get-Command failed: $_" }

# ── 2. PATH env var scan ───────────────────────────────────────
if (-not $found) {
    foreach ($dir in $env:Path -split ';') {
        $candidate = Join-Path $dir.Trim('"') "git.exe"
        if (Test-Path $candidate) {
            $found = $candidate
            Write-Host "Found via PATH env: $found"
            break
        }
    }
}

# ── 3. Common Program Files locations ─────────────────────────
$commonPaths = @(
    "${env:ProgramFiles}\Git\bin\git.exe"
    "${env:ProgramFiles}\Git\cmd\git.exe"
    "${env:ProgramFiles(x86)}\Git\bin\git.exe"
    "${env:ProgramFiles(x86)}\Git\cmd\git.exe"
    "${env:LOCALAPPDATA}\Programs\Git\bin\git.exe"
    "${env:LOCALAPPDATA}\Programs\Git\cmd\git.exe"
    "${env:ProgramFiles}\Git\mingw64\bin\git.exe"
    "${env:SystemDrive}\Program Files\Git\bin\git.exe"
    "${env:SystemDrive}\Program Files\Git\cmd\git.exe"
)

if (-not $found) {
    foreach ($p in $commonPaths) {
        if (Test-Path $p) {
            $found = $p
            Write-Host "Found in common locations: $found"
            break
        }
    }
}

# ── 4. Registry (Git for Windows) ──────────────────────────────
if (-not $found) {
    $regPaths = @(
        "HKLM:\SOFTWARE\GitForWindows\InstallPath"
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1\InstallLocation"
        "HKLM:\SOFTWARE\WOW6432Node\GitForWindows\InstallPath"
    )
    foreach ($rp in $regPaths) {
        try {
            $installDir = (Get-ItemProperty -Path $rp -ErrorAction Stop).'(default)'
            if (-not $installDir) { $installDir = (Get-ItemProperty -Path $rp -ErrorAction Stop).'InstallLocation' }
            if (-not $installDir) { $installDir = (Get-ItemProperty -Path $rp -ErrorAction Stop).'InstallPath' }
            if ($installDir) {
                $candidate = Join-Path $installDir.TrimEnd('\') "bin\git.exe"
                if (-not (Test-Path $candidate)) { $candidate = Join-Path $installDir.TrimEnd('\') "cmd\git.exe" }
                if (Test-Path $candidate) {
                    $found = $candidate
                    Write-Host "Found via registry: $found"
                    break
                }
            }
        } catch { Write-Host "Registry path $rp not found: $_" }
    }
}

# ── 5. Recursive search in Program Files (last resort, shallow) ─
if (-not $found) {
    Write-Host "Searching Program Files recursively (max depth 3)..."
    $searchDirs = @("${env:ProgramFiles}\Git", "${env:ProgramFiles(x86)}\Git")
    foreach ($sd in $searchDirs) {
        if (Test-Path $sd) {
            $results = Get-ChildItem -Path $sd -Filter "git.exe" -Recurse -Depth 3 -ErrorAction SilentlyContinue
            foreach ($r in $results) {
                if ($r.FullName -notmatch '\\usr\\bin\\' -and $r.FullName -notmatch '\\mingw\\') {
                    $found = $r.FullName
                    Write-Host "Found via recursive search: $found"
                    break
                }
            }
        }
        if ($found) { break }
    }
}

# ── Output result (JSON on last line, plain text above) ────────
if ($found) {
    Write-Host "`n=== GIT.EXE PATH ==="
    Write-Host $found
} else {
    Write-Host "`n=== GIT.EXE NOT FOUND ==="
    exit 1
}
