# Windows finance workspace

This fork extends [Sure](https://github.com/we-promise/sure), a community continuation of Maybe Finance. It retains the AGPLv3 license and is not affiliated with or endorsed by Maybe Finance Inc.

## Start locally

Run PowerShell from the repository:

```powershell
.\bin\windows\Setup.ps1 -Email 'owner@localhost' -FirstName 'Owner' -FamilyName 'My finances'
.\bin\windows\Start.ps1
```

Docker Desktop with its Linux/WSL2 backend, Git and PowerShell are required. Setup creates a single local administrator, random local credentials, a HUF reporting workspace, a Europe/Budapest timezone, and private account sharing. Run setup once; existing users and credentials are preserved. Use `-PersonalAccountName` and `-BusinessAccountName` for the exact holders shown in the source exports.

The app opens at **http://localhost:3333/finance**. Only the loopback web port is published; PostgreSQL and Redis remain inside the Compose network. Existing containers use separate names and volumes.

Runtime credentials, original imports, evidence and backups are in the sibling **sure-private** directory, outside the repository/build context. Your local login is in `sure-private/runtime/login.txt`; change its password in Settings. Do not commit or share that directory. The app sends no financial data to an LLM by default.

## Encryption of supported fields

New setup generates three independent encryption keys before creating the user. They protect the model fields that Sure explicitly encrypts, including user PII, MFA secrets and supported provider credentials. Imported CSV text, transaction details and bank-file metadata are not encrypted by this setting; it is not whole-database encryption.

Before upgrading an existing installation, back up its database and private environment file. Setup preserves a complete existing key triplet and refuses a partial one. If all three keys are absent, it derives the exact keys used by the previous self-hosted initializer from the preserved `SECRET_KEY_BASE`, and enables plaintext compatibility so existing users remain readable and searchable. Custom dotenv interpolation or escaped secret values require an explicit migration instead of guessed keys.

After setup, use the existing backfill task with the same environment:

```powershell
. .\bin\windows\Common.ps1
Invoke-SureCompose run --rm web bin/rails 'security:backfill_encryption[100,true]'
Invoke-SureCompose run --rm web bin/rails 'security:backfill_encryption[100,false]'
```

Check the task's failure counts, encrypted-field coverage and existing login before setting `ACTIVE_RECORD_ENCRYPTION_SUPPORT_UNENCRYPTED_DATA=false` in the private environment file and recreating web and worker. The task covers a defined set of models; its success alone does not prove every field was migrated. Preserve all three keys with backups. Setup never rotates existing keys, and the verification service does not inherit production encryption keys.

## Import bank files

1. Open **Finance** and select Personal or Business.
2. Upload the original UTF-8 English bank CSV and inspect its detected format, currencies, coverage, fees, refunds, warnings and sample rows.
3. Confirm the staged upload. The server verifies its checksum, uploader, family and account permissions again.
4. Re-uploading an unchanged Wise export skips existing bank identities. Overlapping Wise history exports retain distinct currency funding legs.

Supported formats: Wise transaction-history CSV, Wise currency-statement CSV, and standard English Revolut account CSV. Save Excel exports as CSV before uploading. A file can contain at most 10 MB or 10,000 source rows.

The import preserves bank categories, separates fees, identifies explicit internal FX and exact self-holder movements, and displays refunds as a subset of received money. Income-prefixed categories are labels for cash received, not tax determinations. Category spending nets refund credits. All amounts remain in their original currency; mixed currencies are never added as if they were HUF.

### Review boundaries

- Outgoing rows marked REFUNDED with a positive amount are held for review because a transaction-history export does not prove the debit/reversal chronology.
- Nonzero-fee Revolut rows are held until their fee treatment can be reconciled against a statement.
- ID-less Revolut exports may be repeated exactly, but overlapping dates from different files are rejected instead of risking a mistaken merge.
- Mixing Wise history and statement formats on the same mapped account, importing into a newly live-linked mapped account, or encountering changed values for a recorded bank identity requires reconciliation.
- Review badges remain visible after import. Originals and receipts retain the audit trail.
- Transfers between separately imported personal and business accounts require exact counterpart matching; ambiguous transfers must be reviewed.

These rules can make coverage incomplete. The dashboard shows the dates actually covered and keeps unresolved reviews visible.

## Balances and reporting

Transaction history does not supply a verified opening or closing balance. History accounts therefore start with **unverified balances**, are excluded from native net-worth reports, and are skipped by balance calculation even during a manual refresh. The Finance page reports observed cash movement and does not invent current net worth.

There is deliberately no automatic switch that treats a partial-history sum as a bank balance. A fresh balance-bearing statement or a functioning read-only bank connection must be reconciled before enabling complete balance reporting.

## Live connections

The existing Sure provider setup remains available from Finance. Credentials and bank consent are configured by the account owner; this fork does not initiate payments.

- **Wise:** its current [personal-token documentation](https://docs.wise.com/guides/developer/auth-and-security/personal-api-token) restricts statement retrieval for accounts based outside the listed supported countries, which excludes Hungary. Sure's existing Wise provider can fall back to transfer/activity data; partial fallback coverage must not be described as verified statement sync.
- **Personal Revolut:** Revolut states there is no public personal-account API. Use the existing aggregator/consent route where the actual bank and account type are supported.
- **Enable Banking:** register an application, configure the exact callback displayed by Sure, and authorize the bank. Restricted production [own-account access](https://enablebanking.com/docs/api/linked-accounts/) is for evaluation/individual non-commercial use under the provider's terms. Do not assume it grants unrestricted business-account use.

No live connection is created by setup. CSV importing remains usable without a provider account or paid AI service.

## Backups and updates

Start enables a daily local full backup at 02:00 UTC with 14-day retention. Run an additional backup before updates:

```powershell
.\bin\windows\Backup.ps1
.\bin\windows\Start.ps1 -Build
```

Backups include the database, uploaded files and secret configuration. Keep them private. Local builds retain version and commit tags on the Docker image so the backup manifest identifies the matching source and image. Preserve these images and the source revision with the backup. See the upstream Docker hosting guide before restoring; never restore over a running instance without a reviewed recovery plan.

## Verification

The verification profile uses a separate test database and Redis. The [Windows verification guide](windows-verification.md) builds a small verification layer over the exact application image, adds the Git/Node tools used by the full test suite, and mounts tracked workflow and configuration examples read-only.

Follow that guide to prepare the isolated test database and run the full Rails gate. Selenium is available on the internal network for browser checks. Record test results against the exact source commit before publishing changes.
