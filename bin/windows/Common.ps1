$ErrorActionPreference = 'Stop'
$RepositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$PrivateRoot = Join-Path (Split-Path $RepositoryRoot -Parent) 'sure-private'
$EnvironmentFile = Join-Path $PrivateRoot 'runtime\.env'
$ComposeFile = Join-Path $RepositoryRoot 'compose.windows.yml'

function Invoke-SureCompose {
    $PreviousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & docker compose --env-file $EnvironmentFile -f $ComposeFile @args 2>&1 | ForEach-Object { $_.ToString() }
    $CommandExit = $LASTEXITCODE
    $ErrorActionPreference = $PreviousPreference
    if ($CommandExit -ne 0) { throw "Sure command failed with exit code $CommandExit." }
}

function Update-SureBuildRevision {
    $BuildRevision = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $BuildRevision -notmatch '^[0-9a-f]{40}$') { throw 'Cannot determine the source revision.' }
    $PendingChanges = & git -C $RepositoryRoot status --porcelain
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the source checkout.' }
    if ($PendingChanges) { throw 'Commit local source changes before building so backup image identities remain reproducible.' }
    $EnvironmentText = [IO.File]::ReadAllText($EnvironmentFile)
    $RevisionPattern = '(?m)^BUILD_COMMIT_SHA=[^\r\n]*'
    if ([regex]::Matches($EnvironmentText, $RevisionPattern).Count -ne 1) { throw 'Expected one BUILD_COMMIT_SHA in the private environment file.' }
    $EnvironmentText = [regex]::Replace($EnvironmentText, $RevisionPattern, "BUILD_COMMIT_SHA=$BuildRevision")
    [IO.File]::WriteAllText($EnvironmentFile, $EnvironmentText, [Text.UTF8Encoding]::new($false))
}

function Test-SureDocker {
    $PreviousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & docker info --format '{{.ServerVersion}}' *> $null
        return $LASTEXITCODE -eq 0
    } finally {
        $ErrorActionPreference = $PreviousPreference
    }
}

function Start-SureDocker {
    if (Test-SureDocker) { return }
    $DockerDesktop = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if (!(Test-Path $DockerDesktop)) { throw 'Install Docker Desktop with the WSL2 backend first.' }
    Start-Process $DockerDesktop
    $Deadline = (Get-Date).AddSeconds(55)
    do {
        Start-Sleep -Seconds 2
        if (Test-SureDocker) { return }
    } while ((Get-Date) -lt $Deadline)
    throw 'Docker is still starting. Wait for Docker Desktop, then run this command again.'
}
