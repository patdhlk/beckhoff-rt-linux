param([string]$NetId = '0.18.52.86.1.1', [int]$Port = 10000)
Add-Type -Path 'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v160\TwinCAT.Ads.dll'
$c = New-Object TwinCAT.Ads.TcAdsClient
try {
  $c.Connect($NetId, $Port)
  $s = $c.ReadState()
  Write-Output ("OK AdsState=" + $s.AdsState + " DeviceState=" + $s.DeviceState)
  try { $info = $c.ReadDeviceInfo(); Write-Output ("DeviceInfo: " + $info.DeviceName + " v" + $info.Version.ToString()) } catch { Write-Output ("DeviceInfo failed: " + $_.Exception.Message) }
} catch {
  Write-Output ("FAIL: " + $_.Exception.GetType().Name + ": " + $_.Exception.Message)
  if ($_.Exception.InnerException) { Write-Output ("  inner: " + $_.Exception.InnerException.Message) }
} finally { $c.Dispose() }
