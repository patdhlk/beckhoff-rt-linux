param([string]$NetId = '0.18.52.86.1.1')
Add-Type -Path 'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v160\TwinCAT.Ads.dll'
foreach ($p in 10000, 851) {
  $c = New-Object TwinCAT.Ads.TcAdsClient
  try { $c.Connect($NetId, $p); $s = $c.ReadState(); Write-Output ("port " + $p + ": AdsState=" + $s.AdsState + " DeviceState=" + $s.DeviceState) }
  catch { Write-Output ("port " + $p + ": " + $_.Exception.InnerException.Message) }
  finally { $c.Dispose() }
}
$c = New-Object TwinCAT.Ads.TcAdsClient
try {
  $c.Connect($NetId, 851)
  $h = $c.CreateVariableHandle('MAIN.nCounter')
  $v1 = $c.ReadAny($h, [type][uint32]); Start-Sleep -Milliseconds 2000; $v2 = $c.ReadAny($h, [type][uint32])
  Write-Output ("MAIN.nCounter: " + $v1 + " -> " + $v2 + " after 2 s (delta " + ($v2 - $v1) + ")")
  $c.DeleteVariableHandle($h)
  try { $h2 = $c.CreateVariableHandle('TwinCAT_SystemInfoVarList._TaskInfo[1].CycleTime'); $ct = $c.ReadAny($h2, [type][uint32]); Write-Output ("Task1 CycleTime (100ns units): " + $ct); $c.DeleteVariableHandle($h2) } catch { Write-Output ("cycle time read: " + $_.Exception.InnerException.Message) }
  try { $h3 = $c.CreateVariableHandle('TwinCAT_SystemInfoVarList._TaskInfo[1].CycleCount'); $cc1 = $c.ReadAny($h3, [type][uint32]); Start-Sleep -Milliseconds 1000; $cc2 = $c.ReadAny($h3, [type][uint32]); Write-Output ("Task1 CycleCount: " + $cc1 + " -> " + $cc2 + " in 1 s"); $c.DeleteVariableHandle($h3) } catch { Write-Output ("cycle count read: " + $_.Exception.InnerException.Message) }
  try { $h4 = $c.CreateVariableHandle('TwinCAT_SystemInfoVarList._TaskInfo[1].CycleTimeExceededCount'); $ex = $c.ReadAny($h4, [type][uint32]); Write-Output ("Task1 CycleTimeExceededCount: " + $ex); $c.DeleteVariableHandle($h4) } catch { Write-Output ("exceeded read: " + $_.Exception.InnerException.Message) }
} catch { Write-Output ("FAIL: " + $_.Exception.Message) } finally { $c.Dispose() }
