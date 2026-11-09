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
        "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=$(New-SureSecret)",
        "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=$(New-SureSecret)",
        "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=$(New-SureSecret)",
        'ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA=false',
        "SURE_PERSONAL_ACCOUNT_NAME=$PersonalAccountName", "SURE_BUSINESS_ACCOUNT_NAME=$BusinessAccountName"
    )
    [IO.File]::WriteAllLines($EnvironmentFile, $ConfigLines, (New-Object Text.UTF8Encoding($false)))
} else {
    $EncryptionNames = @(
        'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY',
        'ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY',
        'ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT'
    )
    $EnvironmentLines = [IO.File]::ReadAllLines($EnvironmentFile)
    $StoredEncryption = @{}
    foreach ($EncryptionName in ($EncryptionNames + @('SECRET_KEY_BASE'))) {
        $Definitions = @($EnvironmentLines | Where-Object { $_ -match "^\s*$EncryptionName\s*=" })
        if ($Definitions.Count -gt 1) { throw "Duplicate $EncryptionName definitions; resolve them before setup." }
        $StoredValue = if ($Definitions.Count -eq 1) { $Definitions[0].Substring($Definitions[0].IndexOf('=') + 1).Trim() } else { '' }
        if ($StoredValue.Length -ge 2 -and (
            ($StoredValue.StartsWith('"') -and $StoredValue.EndsWith('"')) -or
            ($StoredValue.StartsWith("'") -and $StoredValue.EndsWith("'"))
        )) { $StoredValue = $StoredValue.Substring(1, $StoredValue.Length - 2) }
        $StoredEncryption[$EncryptionName] = $StoredValue
    }

    $PresentEncryptionNames = @($EncryptionNames | Where-Object { ![string]::IsNullOrWhiteSpace($StoredEncryption[$_]) })
    if ($PresentEncryptionNames.Count -gt 0 -and $PresentEncryptionNames.Count -lt 3) {
        throw 'Encryption keys are partially configured. Restore the complete original triplet before setup; keys will not be replaced.'
    }
    if ($PresentEncryptionNames.Count -eq 0) {
        $StoredSecretBase = $StoredEncryption['SECRET_KEY_BASE']
        # The setup-generated secret is literal hex. Refuse dotenv interpolation
        # or escaped custom values rather than derive keys from the wrong bytes.
        if ($StoredSecretBase -notmatch '^[A-Za-z0-9_+/=-]+$') {
            throw 'Legacy encryption upgrade requires a literal SECRET_KEY_BASE. Preserve custom secrets and migrate their encryption keys explicitly.'
        }
        $KeyPurposes = @('primary_key', 'deterministic_key', 'key_derivation_salt')
        $EncryptionLines = @()
        $Hasher = [Security.Cryptography.SHA256]::Create()
        try {
            for ($KeyIndex = 0; $KeyIndex -lt $EncryptionNames.Count; $KeyIndex++) {
                $KeyBytes = [Text.Encoding]::UTF8.GetBytes("${StoredSecretBase}:$($KeyPurposes[$KeyIndex])")
                $DerivedKey = ([BitConverter]::ToString($Hasher.ComputeHash($KeyBytes))).Replace('-', '').ToLowerInvariant()
                $EncryptionLines += "$($EncryptionNames[$KeyIndex])=$DerivedKey"
            }
        } finally { $Hasher.Dispose() }
        $EncryptionLines += 'ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA=true'
        $PreservedLines = @($EnvironmentLines | Where-Object {
            $_ -notmatch '^\s*ACTIVE_RECORD_ENCRYPTION_(PRIMARY_KEY|DETERMINISTIC_KEY|KEY_DERIVATION_SALT|SUPPORT_UNENCRYPTED_DATA)\s*='
        })
        [IO.File]::WriteAllLines($EnvironmentFile, ($PreservedLines + $EncryptionLines), (New-Object Text.UTF8Encoding($false)))
        Write-Output 'Encryption keys are configured. Plaintext compatibility is enabled until the existing data is backfilled.'
    }
}

$BootstrapFile = Join-Path $PrivateRoot 'runtime\bootstrap.json'
if (!(Test-Path $BootstrapFile)) {
    $Password = New-SureSecret 18
    $Profile = @{ email=$Email; password=$Password; first_name=$FirstName; last_name=$LastName; family_name=$FamilyName }
    [IO.File]::WriteAllText($BootstrapFile, ($Profile | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    $Login = @("Sure local login", "URL: http://localhost:3333/finance", "Email: $Email", "Password: $Password", "", "Change your password in Settings after first sign-in. Keep this file private.") -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $PrivateRoot 'runtime\login.txt'), $Login, (New-Object Text.UTF8Encoding($false)))
}

Start-SureDocker
Invoke-SureCompose config --quiet
if (!$SkipBuild) { Update-SureBuildRevision; Invoke-SureCompose build web }
Invoke-SureCompose up -d web
Invoke-SureCompose run --rm -v "${PrivateRoot}/runtime:/bootstrap:ro" -v "${RepositoryRoot}/bin/windows/bootstrap.rb:/bootstrap_script.rb:ro" web bin/rails runner /bootstrap_script.rb
Invoke-SureCompose --profile backup up -d worker backup
Write-Output 'Sure is ready at http://localhost:3333/finance'
Write-Output "Your login is in $PrivateRoot\runtime\login.txt"
