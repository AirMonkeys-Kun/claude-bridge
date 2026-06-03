$pipe = New-Object System.IO.Pipes.NamedPipeClientStream(".", "Cluster_Wkr_user", [System.IO.Pipes.PipeDirection]::InOut)
$pipe.Connect(5000)
$reader = New-Object System.IO.StreamReader($pipe)
$writer = New-Object System.IO.StreamWriter($pipe)
$writer.AutoFlush = $true

$cmd = '{"id":"pipe_test","c":"whoami","t":"powershell","to":10}'
$writer.WriteLine($cmd)
$result = $reader.ReadLine()
Write-Host "RESULT: $result"

$pipe.Close()
