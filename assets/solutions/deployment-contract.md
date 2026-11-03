# Lab 6 application deployment contract

This document is the participant-facing contract for the instructor-provisioned
Lab 04 platform. Use it when creating the Lab 6 Dockerfile, `.dockerignore`, test
project, and GitHub Actions workflow. You do not need the infrastructure source or permission
to redeploy it.

The platform already exists. Lab 6 builds and validates an application image,
pushes it to the existing Azure Container Registry (ACR), and updates only the
image on the existing Azure Container App.

## Application build contract

| Item | Contract |
| --- | --- |
| Solution | `eShopLiteFx.sln` (repository root) |
| Web project | `src/eShopLite.StoreFx/eShopLite.StoreFx.csproj` |
| Test project | `tests/eShopLite.StoreFx.Tests/eShopLite.StoreFx.Tests.csproj` |
| Required Lab 6 target framework | .NET 10 (`net10.0`) |
| Entry assembly | `eShopLite.StoreFx.dll` |
| Docker build context | `.` (repository root) |
| Dockerfile | `src/eShopLite.StoreFx/Dockerfile`, relative to the build context |
| Container port | `8080` |

The repository starts with this solution as ASP.NET MVC 5 on .NET Framework
4.8. Labs 02 and 03 modernize the solution in place. By Lab 6, the project must
be the .NET 10 application described by this contract. If the project still
contains `<TargetFrameworkVersion>v4.8</TargetFrameworkVersion>` or depends on
`System.Web`, stop and complete the earlier modernization work before creating
the Linux container.

The Dockerfile must:

- use `mcr.microsoft.com/dotnet/sdk:10.0` only for restore and publish
- use `mcr.microsoft.com/dotnet/aspnet:10.0` for the final image
- restore using the solution/project files before copying the remaining source
  so dependency layers can be cached; if restoring the solution, copy every
  referenced project file, including the test project, before restore
- publish the web project in `Release` configuration
- keep test execution and test output out of the final production image
- run `eShopLite.StoreFx.dll` as a non-root user
- listen on port `8080`
- contain no passwords, connection strings, tokens, client secrets, or
  environment-specific endpoints

The `.dockerignore` must exclude at least:

- `.git`, `.github`, IDE metadata, and editor state
- `**/bin`, `**/obj`, test results, coverage output, and local publish output
- `.env` variants, `connectionStrings.config`, user-specific project files,
  certificates, and other local secret files

A `.dockerignore` only controls files sent to the Docker daemon. It does not
prevent MSBuild from publishing a value already included by the project.
Inspect committed application configuration before building the image.

### Test project requirement

Create the test project above if it is absent. Target `net10.0`, use xUnit,
`Microsoft.NET.Test.Sdk`, and the xUnit Visual Studio test adapter with compatible
stable versions. Reference the web project and add the test project to
`eShopLiteFx.sln`, including its Release build configuration.

Implement small, deterministic tests against the existing `LocalUrl` helper:

- `IsLocal` accepts `/` and `/Products`.
- `IsLocal` rejects null, empty strings, absolute external URLs, `//example.com`,
  slash-backslash host paths, and paths containing control characters.
- `OrHome` converts `~/Products` to `/Products`.
- `OrHome` returns `/` for an external URL.

Tests must exercise application behavior, not unconditional passing assertions.
They must require no database, Azure login, network access, credentials, or
running application. Package restore may require network access.

Run these commands and confirm tests are discovered and pass:

```bash
dotnet restore eShopLiteFx.sln
dotnet build eShopLiteFx.sln --configuration Release --no-restore
dotnet test tests/eShopLite.StoreFx.Tests/eShopLite.StoreFx.Tests.csproj --configuration Release --no-build
```

The workflow must run the explicit test project so a missing project fails
validation rather than silently testing nothing. Include `tests/**` in both
pull-request and push trigger paths. Retain the separate container `/health`
smoke test; unit tests do not replace container validation.

## Container Apps platform contract

The existing Azure Container App runs in an internal Container Apps managed
environment. Azure Front Door Premium reaches that environment through Private
Link and is the public entry point.

| Setting | Deployed contract |
| --- | --- |
| Ingress | Enabled for the app inside the managed environment |
| Insecure ingress | Disabled |
| Target port | `8080` |
| Transport | Automatic |
| Revision mode | Single |
| Workload profile | Consumption |
| Minimum replicas | 2 |
| Maximum replicas | 10 |
| Scale rule | HTTP concurrency, 50 concurrent requests |
| Session affinity | Disabled |
| Registry | Existing Lab 04 ACR |
| Registry authentication | User-assigned retail runtime identity |
| Public route | Existing Front Door endpoint |

The Container App has both system-assigned and user-assigned identity types,
but the **user-assigned retail runtime identity** is the identity configured for
ACR pulls. The same user-assigned identity is selected inside the application
through `AZURE_CLIENT_ID`.

Lab 6 must not recreate the Container App, managed environment, registry,
network, Front Door profile, identities, role assignments, secrets, replica
limits, or scaling rules.

## Runtime configuration contract

The platform owns the application runtime settings. GitHub Actions may verify
them but must not set, replace, or remove them.

| Configuration key | Required | Source and behavior |
| --- | --- | --- |
| `ASPNETCORE_ENVIRONMENT` | Yes | Set to `Production` by the platform |
| `AZURE_CLIENT_ID` | Yes | Client ID of the user-assigned retail runtime identity |
| `ConnectionStrings__StoreDbContext` | Yes | Passwordless SQL connection supplied after platform/database provisioning |
| `KeyVault__Uri` | No | Adds Key Vault configuration using managed identity; loaded after environment variables and can override them |
| `Redis__Endpoint` | No | Redis host and port; enables shared session/cart storage with Entra ID authentication; empty means per-replica memory |
| `DataProtection__BlobUri` | No | Empty means data-protection keys are local to each replica |
| `DataProtection__KeyVaultKeyUri` | No | Optionally wraps persisted keys; requires `DataProtection__BlobUri` |
| `DataProtection__ApplicationName` | No | Sets a stable data-protection application discriminator |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | No | Empty disables the Azure Monitor exporter |
| `ASPNETCORE_HTTP_PORTS` | Image default | Dockerfile sets `8080`; keep aligned with ingress |
| `AllowedHosts` | No | Standard ASP.NET Core host filtering; committed default is `*` |
| `Logging__LogLevel__Default` | No | Standard logging; committed default is `Information` |
| `Logging__LogLevel__Microsoft.AspNetCore` | No | Standard logging; committed default is `Warning` |

These are the application-specific configuration reads plus the configured
ASP.NET Core hosting/logging settings. Standard .NET configuration providers also
accept environment overrides. The app does not read `ConnectionStrings__Redis`,
`ConnectionStrings__AzureSignalR`, `DataProtection__KeyVaultKeyId`, or
`ApplicationInsights__ConnectionString`. It uses static server-rendered Razor
components, not interactive Blazor circuits, and has no Azure SignalR integration.

The required SQL connection uses a managed-identity access token acquired by the
application. The connection string supplies the server and database; legacy
authentication keywords and user identifiers are ignored by the application:

```text
Server=tcp:<server>,1433;Initial Catalog=eshop;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;
```

It contains identifiers and endpoints but no credential. Lab 05 grants the
runtime identity `db_datareader` and `db_datawriter` in the migrated `eshop`
database. The separately imported `eshop_ai` database is not the retail
application database.

The app acquires a token for `https://database.windows.net/.default` through
the configured managed identity, then assigns it to the EF6 SQL connection.
`/ready` opens the configured database connection and executes `SELECT 1`.
Local container smoke tests supply a nonproduction dummy value and probe
`/health`, which intentionally does not require Azure credentials. Committed
`appsettings.json` contains only logging and host-filtering defaults, not a SQL
connection string. The current SQL provider incompatibility is described below.

## Health and ingress contract

The application exposes:

| Endpoint | Meaning | Expected use |
| --- | --- | --- |
| `/health` | Process liveness only | Local and release smoke tests |
| `/ready` | Opens the configured SQL connection and executes `SELECT 1` | Release database-access gate |

The current application does not expose `/health/live`, `/healthz`, or
`/health/ready`.

The Docker image must listen on `0.0.0.0:8080`. Do not use the development
launch profile's port `5000`; launch profiles are not used by the published
container.

For local validation, publish `8080:8080` and probe `/health`. After release,
probe `/health` through Front Door and separately inspect revision health.

## GitHub Actions contract

The repository bootstrap creates two protected GitHub environments and
publishes non-secret variables from the instructor deployment.

### Environments and identities

| Environment | Identity | Required access |
| --- | --- | --- |
| `lab06` | Dedicated build identity | `AcrPush` on the existing ACR |
| `lab06-deploy` | Dedicated deployment identity | `Container Apps Contributor` on the retail app and `Reader` on the Front Door profile |

Both jobs authenticate with GitHub OIDC. Do not use Azure client secrets, ACR
admin credentials, SQL passwords, or long-lived tokens.

### Variables

| Variable | Purpose |
| --- | --- |
| `AZURE_CLIENT_ID` | Environment-specific build or deployment identity |
| `AZURE_TENANT_ID` | Azure Login tenant |
| `AZURE_SUBSCRIPTION_ID` | Azure Login subscription |
| `LAB06_CONTAINER_REGISTRY_NAME` | Existing ACR name |
| `LAB06_CONTAINER_APP_NAME` | Existing retail Container App name |
| `LAB06_RUNTIME_IDENTITY_RESOURCE_ID` | Expected user-assigned registry/runtime identity |
| `LAB06_RUNTIME_IDENTITY_CLIENT_ID` | Client ID selected by `AZURE_CLIENT_ID` inside the app |
| `LAB04_PRIMARY_RESOURCE_GROUP` | Registry lookup scope |
| `LAB04_SECONDARY_RESOURCE_GROUP` | Container App lookup scope |
| `LAB04_GLOBAL_RESOURCE_GROUP` | Front Door lookup scope |
| `LAB04_PREFIX`, `LAB04_SUFFIX` | Front Door profile naming inputs |

### Workflow ownership boundary

Pull requests:

- restore, build, and test .NET
- build the container
- run it with a dummy connection string
- probe `http://127.0.0.1:8080/health`
- receive no Azure token and push no image

Pushes to `main`:

- repeat validation
- use the `lab06` identity to push `sha-<full-commit-sha>`
- resolve the ACR manifest digest
- on the first release only, if the current ready revision uses
  `mcr.microsoft.com/dotnet/samples:aspnetapp`, copy that image into
  `caldova-retail:platform-bootstrap-baseline`, lock that tag, and record its
  ACR digest as the rollback image
- pass `registry/repository@sha256:<digest>` to the deployment job
- require approval through `lab06-deploy`
- verify the target app, the attached runtime identity, the ACR registry
  identity, and the required environment-variable names
- update **only** the image
- wait for the revision to become healthy
- probe `/health` and `/ready` through Front Door; `/ready` must pass before
  the release is reported successful

## Known application and platform mismatches

Report these mismatches; do not silently redesign instructor-owned
infrastructure during Lab 6.

1. **Platform probes do not use the explicit health endpoints.** The current
   Container App template probes `/`, while the application defines dedicated
  `/health` and SQL-backed `/ready` endpoints. The release workflow checks both
  explicitly; changing platform probes is an infrastructure change.
2. **Scale-out state is not fully configured.** The platform starts two
  replicas with session affinity disabled. Without `Redis__Endpoint`, sessions
  and carts are replica-local. Azure SignalR is not part of this static
  server-rendered application and would not fix its session storage.
3. **Data-protection keys are not persisted by default.** With two replicas,
   authentication cookies and antiforgery tokens can become invalid across
   replicas or restarts until Blob/Key Vault settings are supplied.
4. **SQL managed-identity access must be verified before release.** EF6 uses
  `System.Data.SqlClient`, which does not support the managed-identity
  connection-string keyword. The application removes those authentication
  fields and attaches an Azure SQL access token directly. The release smoke
  test must require `/ready` to pass before succeeding.
5. **Older Lab 6 language may mention system-identity ACR pull.** The current
   template grants `AcrPull` to, and configures the registry with, the
   user-assigned retail runtime identity. Live deployments may differ; verify
   the registry identity before release.

Redis, durable data protection, and Application Insights are
production-hardening concerns. They are valuable findings, but they are not
requirements for completing the image-only Lab 6 deployment.

### Observed Lab 04 deployment

Read-only inspection on 2026-11-01 found:

- Container App: `caldovalab04-66809482-app` in
  `rg-caldova-lab04-secondary`, running the placeholder sample image.
- Registry: `caldovalab04cr66809482.azurecr.io`.
- Ingress targets `8080`; all three probes target `/`; minimum replicas is 2,
  maximum is 10, and sticky sessions are not configured.
- Both system and user-assigned identities are attached, but the live registry
  authentication setting is `system`, not the template's user-assigned runtime
  identity. The image-only workflow must stop for instructor repair rather than
  silently changing it. This inspection does not establish the live RBAC grants.
- The required environment-variable names `ASPNETCORE_ENVIRONMENT`,
  `AZURE_CLIENT_ID`, and `ConnectionStrings__StoreDbContext` are present. No Redis,
  data-protection, Key Vault configuration, or telemetry settings are present.
  Secret values were not inspected.
- The default `sqlMi` template initially omits the SQL environment variable;
  provisioning/migration must supply it later. It is present in this deployment.

## Verification and stop conditions

Before deployment, verify:

```bash
docker image inspect caldova-retail:validation \
  --format '{{json .Config.User}} {{json .Config.ExposedPorts}}'
```

The user must be non-root and the image must expose/listen on `8080`.

The deployment workflow should verify:

```bash
az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$APP_RESOURCE_GROUP" \
  --query '{identities:identity.userAssignedIdentities,registries:properties.configuration.registries,env:properties.template.containers[0].env[].name}'
```

Stop and ask the instructor to repair the platform when:

- the expected Container App or ACR cannot be found
- the user-assigned runtime identity is missing
- ACR authentication uses a different identity
- any required environment-variable name is absent
- the image update would require changing infrastructure or runtime secrets
- the deployed revision becomes unhealthy
- the digest deployed to Container Apps differs from the approved ACR digest
