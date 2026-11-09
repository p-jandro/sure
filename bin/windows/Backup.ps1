. "$PSScriptRoot\Common.ps1"
if (!(Test-Path $EnvironmentFile)) { throw 'Run Setup.ps1 first.' }
Start-SureDocker
Invoke-SureCompose run --rm backup create
Write-Output "Backups are in $PrivateRoot\backups. They contain private financial data and encryption configuration."
