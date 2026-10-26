# Lab 6 application deployment contract

This document is the participant-facing contract for the instructor-provisioned
Lab 04 platform. Use it when creating the Lab 6 Dockerfile, `.dockerignore`, and
GitHub Actions workflow. You do not need the infrastructure source or permission
to redeploy it.

The platform already exists. Lab 6 builds and validates an application image,
pushes it to the existing Azure Container Registry (ACR), and updates only the
image on the existing Azure Container App.

## Application build contract

| Item | Contract |
| --- | --- |
| Solution | `eShopLiteFx.sln` (repository root) |
| Web project | `src/eShopLite.StoreFx/eShopLite.StoreFx.csproj` |
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
  so dependency layers can be cached
- publish the web project in `Release` configuration
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
| `ConnectionStrings__Redis` | No | Empty means per-replica in-memory cart storage |
| `ConnectionStrings__AzureSignalR` | No | Empty means Blazor circuits remain on app replicas |
| `DataProtection__BlobUri` | No | Empty means data-protection keys are local to each replica |
| `DataProtection__KeyVaultKeyId` | No | Optionally wraps persisted data-protection keys |
| `ApplicationInsights__ConnectionString` or `APPLICATIONINSIGHTS_CONNECTION_STRING` | No | Empty disables the Azure Monitor exporter |

The required SQL connection uses managed identity and has this shape:

```text
Server=tcp:<server>,1433;Initial Catalog=eshop;User Id=<runtime-identity-client-id>;Authentication=Active Directory Managed Identity;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;
```

It contains identifiers and endpoints but no credential. Lab 05 grants the
runtime identity `db_datareader` and `db_datawriter` in the migrated `eshop`
database. The separately imported `eshop_ai` database is not the retail
application database.

The app fails at startup when `StoreDbContext` is absent. Local container smoke
tests therefore supply a nonproduction dummy value. The liveness endpoint does
not open a database connection.

## Health and ingress contract

The application exposes:

| Endpoint | Meaning | Expected use |
| --- | --- | --- |
| `/health/live` | Process liveness only | Container liveness |
| `/health` | Backward-compatible process liveness | Local and release smoke tests |
| `/healthz` | Backward-compatible process liveness | Existing automation compatibility |
| `/health/ready` | SQL-backed readiness | Determine whether the app can serve catalog traffic |

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
| `lab06` | Dedicated build identity | `AcrPush` and registry metadata `Reader` on the existing ACR |
| `lab06-deploy` | Dedicated deployment identity | `Container Apps Contributor` on the retail app and `Reader` on the Front Door profile |

Both jobs authenticate with GitHub OIDC. Do not use Azure client secrets, ACR
admin credentials, SQL passwords, or long-lived tokens.

The [repository initializer](../scripts/Initialize-Lab06RepositoryFromResourceGroups.ps1)
uses the active Azure CLI subscription when `-SubscriptionId` is omitted, null,
empty, or whitespace; an explicit nonblank value overrides that selection.
Sign in with `az login` first and check
the active subscription with `az account show`. After verifying the existing
Lab 04 role assignments, the initializer grants the build identity `Reader`
on the registry only if no direct or inherited Reader assignment exists.
The operator needs permission to create role assignments at that scope when
the grant is missing; the initializer does not grant itself that permission.

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
- pass `registry/repository@sha256:<digest>` to the deployment job
- require approval through `lab06-deploy`
- verify the target app, the attached runtime identity, the ACR registry
  identity, and the required environment-variable names
- update **only** the image
- wait for the revision to become healthy
- probe `/health` through Front Door

## Known application and platform mismatches

Report these mismatches; do not silently redesign instructor-owned
infrastructure during Lab 6.

1. **Platform probes do not use the explicit health endpoints.** The current
   Container App template probes `/`, while the application defines dedicated
   liveness and SQL-backed readiness endpoints. Lab 6 smoke tests should use
   `/health`; changing platform probes is an infrastructure change.
2. **Scale-out state is not fully configured.** The platform starts two
   replicas with session affinity disabled. Empty Redis and Azure SignalR
   settings mean carts are replica-local and Blazor circuits have no external
   backplane.
3. **Data-protection keys are not persisted by default.** With two replicas,
   authentication cookies and antiforgery tokens can become invalid across
   replicas or restarts until Blob/Key Vault settings are supplied.
4. **Committed configuration must be sanitized.** The application requires
   `StoreDbContext`, and `appsettings.json` currently contains a default value
   even though runtime deployment supplies an environment override. A
   Dockerfile must not treat committed configuration as a safe place for
   credentials.
5. **Older Lab 6 language may mention system-identity ACR pull.** The current
   deployment grants `AcrPull` to, and configures the registry with, the
   user-assigned retail runtime identity.

Redis, Azure SignalR, durable data protection, and Application Insights are
production-hardening concerns. They are valuable findings, but they are not
requirements for completing the image-only Lab 6 deployment.

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
