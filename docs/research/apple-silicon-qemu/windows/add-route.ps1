$dir = 'C:\ProgramData\Beckhoff\TwinCAT\3.1\Target'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$xml = @'
<?xml version="1.0"?>
<TcConfig xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.beckhoff.com/schemas/2009/05/TcConfig">
	<RemoteConnections>
		<Route>
			<Name>qemu-xar</Name>
			<Address>10.211.55.2</Address>
			<NetId>0.18.52.86.1.1</NetId>
			<Type>TCP_IP</Type>
		</Route>
	</RemoteConnections>
</TcConfig>
'@
Set-Content -Path "$dir\StaticRoutes.xml" -Value $xml -Encoding UTF8
Restart-Service TcSysSrv -Force
Start-Sleep -Seconds 8
(Get-Service TcSysSrv).Status
Write-Output '---STATE via x86 PowerShell'
$env:PATH = 'C:\Program Files (x86)\Beckhoff\TwinCAT\Common32;' + $env:PATH
& "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File '\\Mac\Home\.cache\xar-vm-test\ads-state.ps1'
Write-Output '---UMRT processes'
Get-Process | Where-Object { $_.Name -like 'Tc*' } | Format-Table -AutoSize Name,Id
