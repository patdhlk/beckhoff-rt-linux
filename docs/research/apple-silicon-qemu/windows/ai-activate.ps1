$ErrorActionPreference = 'Continue'
$log = '\\Mac\Home\.cache\xar-vm-test\ai.log'
function L($m) { $line = (Get-Date -Format 'HH:mm:ss') + ' ' + $m; Add-Content -Path $log -Value $line; Write-Output $line }
Remove-Item $log -ErrorAction SilentlyContinue
L "start; PS bitness=$([IntPtr]::Size*8)"
$tmplRoot = 'C:\ProgramData\Beckhoff\TwinCAT\PlcEngineering\PlcTemplates'
$ver = Get-ChildItem $tmplRoot -Directory | Sort-Object { [version]$_.Name } | Select-Object -Last 1
$plcTemplate = Join-Path $ver.FullName 'Standard PLC Template\Standard PLC Template.plcproj'
L "plc template: $plcTemplate exists=$(Test-Path $plcTemplate)"
$dir = 'C:\Users\patdhlk\Documents\TcXaeShell\xar-qemu-test'
if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
try {
  $dte = New-Object -ComObject 'TcXaeShell.DTE.17.0'
  L "DTE created: $($dte.Version)"
  $dte.SuppressUI = $true
  try { $dte.MainWindow.Visible = $false } catch {}
  $sln = $dte.Solution
  $sln.Create($dir, 'xar-qemu-test')
  L "solution created"
  $proj = $sln.AddFromTemplate('C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\PrjTemplate\TwinCAT Project.tsproj', (Join-Path $dir 'xar-qemu-test'), 'xar-qemu-test')
  L "tsproj added: $($proj.Name)"
  $sm = $proj.Object
  $sm.SetTargetNetId('0.18.52.86.1.1')
  L "target set: $($sm.GetTargetNetId())"
  $plc = $sm.LookupTreeItem('TIPC')
  $plcProj = $null
  foreach ($t in @('Standard PLC Template.plcproj', 'Standard PLC Template', $plcTemplate)) {
    try { $plcProj = $plc.CreateChild('QemuPlc', 0, '', $t); L "plc project created with template '$t': $($plcProj.Name)"; break }
    catch { L "CreateChild('$t') failed: $($_.Exception.Message)" }
  }
  if (-not $plcProj) { throw 'no PLC project created' }
  # try to put a counter into MAIN
  try {
    $main = $sm.LookupTreeItem('TIPC^QemuPlc^QemuPlc Project^POUs^MAIN')
    $main.DeclarationText = "PROGRAM MAIN`r`nVAR`r`n`tnCounter : UDINT;`r`nEND_VAR`r`n"
    $main.ImplementationText = "nCounter := nCounter + 1;`r`n"
    L "MAIN code set"
  } catch { L "MAIN edit skipped: $($_.Exception.Message)" }
  $sln.SaveAs((Join-Path $dir 'xar-qemu-test.sln'))
  L "solution saved"
  $sm.ActivateConfiguration()
  L "ActivateConfiguration done"
  $sm.StartRestartTwinCAT()
  L "StartRestartTwinCAT done"
  Start-Sleep -Seconds 20
  try { $dte.Quit() } catch {}
  L "DTE quit"
} catch {
  L "FAIL: $($_.Exception.Message)"
  if ($_.Exception.InnerException) { L "inner: $($_.Exception.InnerException.Message)" }
  try { $dte.Quit() } catch {}
}
L "end"
