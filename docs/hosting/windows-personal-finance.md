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

Backups include the database, uploaded files and secret configuration. Keep them private. Preserve the source revision and local Docker image with the backup. See the upstream Docker hosting guide before restoring; never restore over a running instance without a reviewed recovery plan.

## Verification

The `verification` profile uses a separate test database and Redis. It never points at the production database. Run tests from the built image to avoid slow Windows bind-mount startup:

```powershell
docker compose --env-file ..\sure-private\runtime\.env -f compose.windows.yml --profile verification run --rm test bin/rails test
```

Initialize a fresh test database with `bin/rails db:prepare` first. Selenium is available on the internal network for system tests. Full tests, lint/security checks and browser acceptance should be recorded against the exact source commit before publishing changes.
