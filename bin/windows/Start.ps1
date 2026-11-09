param([switch]$NoBrowser, [switch]$Build)
. "$PSScriptRoot\Common.ps1"
if (!(Test-Path $EnvironmentFile)) { throw 'Run Setup.ps1 once before starting Sure.' }
Start-SureDocker
if ($Build) { Invoke-SureCompose build web }
Invoke-SureCompose --profile backup up -d web worker backup
if (!$NoBrowser) { Start-Process 'http://localhost:3333/finance' }
Write-Output 'Sure is available at http://localhost:3333/finance'
