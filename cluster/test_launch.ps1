$ErrorActionPreference = "Continue"
$testFile = "C:\Users\wsx\Desktop\claude-bridge\cluster\test_launch.txt"
"Started at $(Get-Date)" | Out-File $testFile -Encoding utf8
Start-Sleep -Seconds 30
"Finished at $(Get-Date)" | Out-File $testFile -Append -Encoding utf8
