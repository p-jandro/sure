param(
    [string]$Email = 'owner@localhost',
    [string]$FirstName = 'Owner',
    [string]$LastName = '',
    [string]$FamilyName = 'My finances',
    [string]$PersonalAccountName = '',
    [string]$BusinessAccountName = '',
    [switch]$SkipBuild
)
. "$PSScriptRoot\Common.ps1"
New-Item -ItemType Directory -Force -Path "$PrivateRoot\runtime", "$PrivateRoot\imports", "$PrivateRoot\backups", "$PrivateRoot\evidence" | Out-Null

function New-SureSecret {
    param([int]$Length = 32)
    $Bytes = New-Object byte[] $Length
    $Generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $Generator.GetBytes($Bytes) } finally { $Generator.Dispose() }
    return ([BitConverter]::ToString($Bytes)).Replace('-', '').ToLowerInvariant()
}

if (!(Test-Path $EnvironmentFile)) {
    if ($PersonalAccountName -match '[\r\n]' -or $BusinessAccountName -match '[\r\n]') { throw 'Account names must occupy one line.' }
    $Commit = (& git -C $RepositoryRoot rev-parse HEAD).Trim()
    $ConfigLines = @(
        'PORT=3333', 'SURE_IMAGE_TAG=local', "BUILD_COMMIT_SHA=$Commit",
        "POSTGRES_PASSWORD=$(New-SureSecret)", "SECRET_KEY_BASE=$(New-SureSecret 64)",
        "SURE_PERSONAL_ACCOUNT_NAME=$PersonalAccountName", "SURE_BUSINESS_ACCOUNT_NAME=$BusinessAccountName"
    )
    [IO.File]::WriteAllLines($EnvironmentFile, $ConfigLines, (New-Object Text.UTF8Encoding($false)))
}

$BootstrapFile = Join-Path $PrivateRoot 'runtime\bootstrap.json'
if (!(Test-Path $BootstrapFile)) {
    $Password = New-SureSecret 18
    $Profile = @{ email=$Email; password=$Password; first_name=$FirstName; last_name=$LastName; family_name=$FamilyName }
    [IO.File]::WriteAllText($BootstrapFile, ($Profile | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $Login = "Sure local login\r\nURL: http://localhost:3333/finance\r\nEmail: $Email\r\nPassword: $Password\r\n\r\nChange your password in Settings after first sign-in. Keep this file private."
    [IO.File]::WriteAllText((Join-Path $PrivateRoot 'runtime\login.txt'), $Login, (New-Object Text.UTF8Encoding($false)))
}

Start-SureDocker
Invoke-SureCompose config --quiet
if (!$SkipBuild) { Invoke-SureCompose build web }
Invoke-SureCompose up -d web
Invoke-SureCompose run --rm -v "${PrivateRoot}/runtime:/bootstrap:ro" -v "${RepositoryRoot}/bin/windows/bootstrap.rb:/bootstrap_script.rb:ro" web bin/rails runner /bootstrap_script.rb
Invoke-SureCompose --profile backup up -d worker backup
Write-Output 'Sure is ready at http://localhost:3333/finance'
Write-Output "Your login is in $PrivateRoot\runtime\login.txt"
