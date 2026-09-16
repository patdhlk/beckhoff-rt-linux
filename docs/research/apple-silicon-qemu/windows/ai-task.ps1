$user = 'patdhlk'
$action = New-ScheduledTaskAction -Execute "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \\Mac\Home\.cache\xar-vm-test\ai-activate.ps1"
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Unregister-ScheduledTask -TaskName 'xar-ai' -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName 'xar-ai' -Action $action -Principal $principal -Settings $settings | Out-Null
Start-ScheduledTask -TaskName 'xar-ai'
Write-Output "task started"
$log = '\\Mac\Home\.cache\xar-vm-test\ai.log'
$deadline = (Get-Date).AddMinutes(9)
while ((Get-Date) -lt $deadline) {
  Start-Sleep -Seconds 10
  if ((Test-Path $log) -and ((Get-Content $log -Tail 1) -like '*end*')) { break }
}
Write-Output "task state: $((Get-ScheduledTask -TaskName 'xar-ai').State)"
Get-Content $log -ErrorAction SilentlyContinue
