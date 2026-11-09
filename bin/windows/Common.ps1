$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$PrivateRoot = Join-Path (Split-Path $RepositoryRoot -Parent) 'sure-private'
$EnvironmentFile = Join-Path $PrivateRoot 'runtime\.env'
$ComposeFile = Join-Path $RepositoryRoot 'compose.windows.yml'

function Invoke-SureCompose {
    $PreviousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & docker compose --env-file $EnvironmentFile -f $ComposeFile @args
    $CommandExit = $LASTEXITCODE
    $ErrorActionPreference = $PreviousPreference
    if ($CommandExit -ne 0) { throw "Sure command failed with exit code $CommandExit." }
}

function Start-SureDocker {
    & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return }
    $DockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (!(Test-Path $DockerDesktop)) { throw 'Install Docker Desktop with the WSL2 backend first.' }
    Start-Process $DockerDesktop
    $Deadline = (Get-Date).AddSeconds(55)
    do {
        Start-Sleep -Seconds 2
        & docker info --format '{{.ServerVersion}}' 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { return }
    } while ((Get-Date) -lt $Deadline)
    throw 'Docker is still starting. Wait for Docker Desktop, then run this command again.'
}
