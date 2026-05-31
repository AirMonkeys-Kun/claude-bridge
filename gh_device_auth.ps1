# Claude Bridge — GitHub Device Code Auth Helper
# 实时捕获设备认证码，写入文件供 Claude 读取

$gh = "C:\Program Files\GitHub CLI\gh.exe"
$resultDir = "C:\Users\wsx\Desktop\claude-bridge\watcher"
$codeOutput = Join-Path $resultDir "gh_device_code.txt"
$resultFile = Join-Path $resultDir "r_gh_device_helper.json"

# 先 kill 残留的 gh 进程
taskkill /F /IM gh.exe 2>$null

function Write-Result {
    param($exitCode, $stdout, $stderr, $state)
    $r = @{
        cmd_id = "gh_device_helper"
        state = $state
        exit_code = $exitCode
        stdout = $stdout
        stderr = $stderr
        timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff")
    }
    $r | ConvertTo-Json -Compress | Out-File -FilePath $resultFile -Encoding UTF8
}

try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $gh
    $psi.Arguments = "auth login -h github.com --git-protocol ssh"
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()

    $outputBuilder = New-Object System.Text.StringBuilder
    $codeFound = $false

    # 实时读取 stdout，边读边检查设备码
    while (-not $p.StandardOutput.EndOfStream) {
        $line = $p.StandardOutput.ReadLine()
        [void]$outputBuilder.AppendLine($line)

        # 检查设备码模式 (XXXX-XXXX 或 XXXXXXXX-XXXX)
        if (-not $codeFound -and $line -match '([A-Z0-9]{4,8}-[A-Z0-9]{4,8})') {
            $code = $matches[1]
            $code | Out-File -FilePath $codeOutput -Encoding UTF8
            $codeFound = $true
            Write-Host "DEVICE CODE CAPTURED: $code"
        }
    }

    $fullOutput = $outputBuilder.ToString()
    $stderr = $p.StandardError.ReadToEnd()
    $p.WaitForExit(30000)
    $exitCode = $p.ExitCode

    if ($codeFound) {
        Write-Result -exitCode $exitCode -stdout $fullOutput -stderr $stderr -state "need_auth"
    } else {
        Write-Result -exitCode $exitCode -stdout $fullOutput -stderr $stderr -state "done"
    }
}
catch {
    Write-Result -exitCode -1 -stdout "" -stderr $_.ToString() -state "error"
}
