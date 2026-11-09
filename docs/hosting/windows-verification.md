# Verify the Windows application image

The production image intentionally omits Git, Node.js, environment templates,
and GitHub workflows. The full Rails suite exercises release scripts and checks
the documented configuration, so it needs those inputs. `Dockerfile.verification`
adds Git and Node.js to the already-built application candidate.
`compose.verification.yml` mounts only the two tracked environment templates and
the workflow directory, read-only. It retains the isolated test database, test
Redis, test environment, and evidence directory from `compose.windows.yml`.

Application code, gems, assets, entrypoint, and `BUILD_COMMIT_SHA` come from the
candidate image. There is no source-root mount or application rebuild in the
verification layer. The production Dockerfile and production service images do
not depend on this layer.

## Build the verification image

Run these commands in PowerShell from the same clean checkout used to build
`futurecode/sure:local`. The template and workflow mounts must match that
candidate's source revision. Keep the checkout unchanged during verification.
If the candidate has a different local tag, set `SURE_VERIFY_BASE_IMAGE` to that
tag explicitly before building.

```powershell
Set-Location D:/FutureCode/sure
git status --short
git rev-parse HEAD
docker image inspect futurecode/sure:local --format '{{.Id}}'

$env:SURE_VERIFY_BASE_IMAGE = 'futurecode/sure:local'
$env:SURE_VERIFY_IMAGE = 'futurecode/sure:verification'
$verificationCompose = @(
  '--env-file', '../sure-private/runtime/.env',
  '-f', 'compose.windows.yml',
  '-f', 'compose.verification.yml',
  '--profile', 'verification'
)

docker compose @verificationCompose build test
if ($LASTEXITCODE -ne 0) { throw 'Verification image build failed' }
docker image inspect $env:SURE_VERIFY_IMAGE --format '{{.Id}}'
```

Record the source commit and both image IDs with the test results. Rebuild this
layer whenever the application candidate changes. The build installs only
verification tools; it does not copy the mounted inputs or private runtime
configuration into either image. The private environment file in the command
supplies Compose interpolation for the existing local setup; the `test` service
uses its separate test credentials and databases.

## Run the Rails gate

Use the same PowerShell session and Compose arguments as above. These commands
start only the isolated verification services. Do not run concurrent suites
against this shared test database.

```powershell
docker compose @verificationCompose up -d --wait test-db test-redis
if ($LASTEXITCODE -ne 0) { throw 'Verification services failed to start' }

docker compose @verificationCompose run --rm --no-deps test bin/rails db:test:prepare
if ($LASTEXITCODE -ne 0) { throw 'Test database preparation failed' }

docker compose @verificationCompose run --rm --no-deps test bin/rails test
if ($LASTEXITCODE -ne 0) { throw 'Rails suite failed' }
```

For a focused check of the previously missing inputs and executables, run:

```powershell
docker compose @verificationCompose run --rm --no-deps test bin/rails test test/workflows test/models/provider/openai_test.rb
if ($LASTEXITCODE -ne 0) { throw 'Workflow and OpenAI configuration tests failed' }
```

Browser system tests are a separate gate and need the existing Selenium service:

```powershell
docker compose @verificationCompose up -d selenium
if ($LASTEXITCODE -ne 0) { throw 'Selenium failed to start' }

docker compose @verificationCompose run --rm --no-deps test bin/rails test:system
if ($LASTEXITCODE -ne 0) { throw 'Browser system suite failed' }
```

The current workflow tests execute Bash, GNU date, sed, and awk from the Debian
runtime; the verification build checks their availability. Release workflow
tests use Git only in temporary repositories. Release-note tests execute Node.js
with a mocked GitHub client. Flutter commands are stubbed. The Python step in the
signed iOS upload workflow is not executed by these tests, so Python, Flutter,
Xcode, GitHub CLI, signing credentials, and banking credentials are not required.

This layer verifies the candidate application with extra test tools. It does not
turn a test run into a deployment, exercise live bank connections, or replace a
smoke check of the production image. Report failures, errors, skips, and any
unrun gates separately.
