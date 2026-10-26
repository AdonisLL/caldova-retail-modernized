# Caldova Retail — Storefront (eShopLite.StoreFx)

A small Blazor storefront on .NET 10 (static server rendering), backed by Entity Framework 6 and SQL Server. It lists products and stores, handles sign-in, and keeps a cart. This is the customer-facing app in the Caldova Retail modernization scenario.

## Setup

Before running the app, open [appsettings.json](src/eShopLite.StoreFx/appsettings.json) and replace the placeholder password in the `StoreDbContext` connection string with your SQL Server password.

Then run it with the .NET 10 SDK:

```powershell
dotnet run --project src/eShopLite.StoreFx
```

## Azure configuration (optional)

Each Azure integration turns on only when its setting is present; with none set, the app runs exactly as it does locally. Set them as environment variables (or Key Vault secrets, using `--` instead of `__`). In Azure, the app signs in with its managed identity; in Development it uses your Azure CLI / Visual Studio sign-in.

| Setting | What it turns on |
| --- | --- |
| `ConnectionStrings__StoreDbContext` | SQL connection string; required for database-backed pages |
| `AZURE_CLIENT_ID` | Use this user-assigned managed identity (otherwise the system-assigned one) |
| `KeyVault__Uri` | Key Vault as a configuration source, e.g. a `ConnectionStrings--StoreDbContext` secret |
| `DataProtection__BlobUri` | Keep the sign-in/session/antiforgery key ring in a blob so it survives restarts and is shared by replicas |
| `DataProtection__KeyVaultKeyUri` | Also encrypt that key ring with a Key Vault key (needs `DataProtection__BlobUri`) |
| `DataProtection__ApplicationName` | Fixed app name so all replicas and revisions share keys |
| `Redis__Endpoint` | Keep session (the cart) in Azure Redis, e.g. `myredis.redis.cache.windows.net:6380` |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Send telemetry to Application Insights |
| `ASPNETCORE_FORWARDEDHEADERS_ENABLED` | `true` behind Container Apps ingress, so the app sees the original `https` scheme |
| `Logging__LogLevel__Default`, `Logging__LogLevel__Microsoft.AspNetCore` | Standard ASP.NET Core logging levels |
| `AllowedHosts` | Standard ASP.NET Core host filtering |
| `ASPNETCORE_ENVIRONMENT` | Hosting environment; the platform sets `Production` |

Container Apps probes: `/health` (liveness) and `/ready` (readiness). No dependency checks are registered, so `/ready` currently reports process health, not SQL or Redis availability. See [infra/complete/](infra/complete/README.md) for the Azure infrastructure (Bicep).

## Container image

Build from the repository root (Linux containers):

```powershell
docker build --file src\eShopLite.StoreFx\Dockerfile --tag caldova-retail:local .
docker run --rm --publish 8080:8080 --env ConnectionStrings__StoreDbContext caldova-retail:local
```

Set `ConnectionStrings__StoreDbContext` in the invoking shell before running the
container; `--env` forwards its value without placing it in the image. Probe
`http://localhost:8080/health` or `http://localhost:8080/ready`.

The multi-stage build restores and publishes the single .NET 10 web project,
including its Razor components and static assets. Only published output enters
the ASP.NET 10 runtime image, which starts `eShopLite.StoreFx.dll` as the built-in
non-root `app` user (`APP_UID`) on port 8080. The SDK is not in the final image.
Development launch profiles are not used.

The root [.dockerignore](.dockerignore) excludes all `appsettings*.json` files,
including the checked-in SQL connection string, from **every build stage**.
It also excludes local secrets, certificates, build output, IDE state, and Git
metadata. Supply configuration at runtime through environment variables or the
optional Key Vault provider. Logging and host-filter settings from the excluded
JSON also need environment variables if values other than framework defaults
are required. Never pass secrets through Dockerfile `ARG`, `ENV`, or source files.

### Lab 04 integration gaps

The infrastructure and application are not yet a complete retail deployment:

- **Image and registry:** the platform defaults to the ASP.NET sample image.
  Push the retail image to the existing ACR and update only the app image as
  described in the [deployment contract](assets/solutions/deployment-contract.md).
  Registry pulls use the user-assigned runtime identity, not registry passwords;
  `AZURE_CLIENT_ID` selects that same identity for application Azure clients.
- **SQL authentication:** [StoreDbContext](src/eShopLite.StoreFx/Data/StoreDbContext.cs)
  uses EF6's `System.Data.SqlClient` provider. It does not support the platform's
  `Authentication=Active Directory Managed Identity` connection string.
  A compatible provider migration is needed; setting `AZURE_CLIENT_ID` alone
  does not make the existing database provider use managed identity.
- **SQL provisioning:** the default SQL MI path omits the SQL environment
  variable in Bicep and relies on external importer automation to add it later.
  The live Lab 04 app inspected for this change has only
  `ASPNETCORE_ENVIRONMENT` and `AZURE_CLIENT_ID`, so its SQL configuration is
  still missing. The imported `eshop_ai` database is distinct from the retail
  app's expected `eshop`; Lab 05 must migrate it and grant database access.
- **Probes:** Container Apps startup/liveness/readiness probes and Front Door
  probes target `/`, which renders the static home page, not a dedicated health
  endpoint, and does not verify database availability. Configure process
  probes to use `/health` and readiness to use `/ready`, after adding real
  dependency checks if SQL-backed readiness is required. The contract's
  `/health/live`, `/healthz`, and `/health/ready` routes do not exist in this app.
- **Configuration names:** the app reads `Redis__Endpoint`, not
  `ConnectionStrings__Redis`; `DataProtection__KeyVaultKeyUri`, not
  `DataProtection__KeyVaultKeyId`; and `APPLICATIONINSIGHTS_CONNECTION_STRING`,
  not `ApplicationInsights__ConnectionString`. It has no Azure SignalR
  integration (it uses static server rendering, not interactive Blazor circuits).
  `KeyVault__Uri` and `DataProtection__ApplicationName` are additional supported
  settings. A Key Vault provider, when configured, overrides environment values.
- **Replica state:** the platform runs at least two replicas without affinity,
  but does not provision/configure Redis or a shared Data Protection blob/key.
  Without those integrations, carts and cookies are not reliably shared across
  replicas or preserved across restarts. Blob, Redis, and optional Key Vault key
  permissions must be supplied before enabling them; Secrets User alone does
  not grant blob access or key wrapping permissions.
- **Proxy headers:** the platform does not supply
  `ASPNETCORE_FORWARDEDHEADERS_ENABLED`; configure it at runtime behind ingress
  so authentication redirects observe the original HTTPS scheme.
- **Documentation drift:** the infrastructure README describes a zone-redundant
  environment, while the Bicep explicitly sets `zoneRedundant: false`. The
  deployment contract also says a missing SQL setting fails startup, but this
  app has no explicit startup validation and its health endpoints do not query SQL.

The container files do not change any Azure resources or repair these application
integration gaps.

# 🔑 Demo logins

The lab applications ship with seeded accounts. Whenever a module tells you to sign in, these are the credentials.

## Caldova storefront

| Username | Password | Role | Notes |
| --- | --- | --- | --- |
| `alice` | `Password1!` | Admin, Manager | Has existing order history |
| `bob` | `Password1!` | Employee | Has existing order history |

Either account works for the sign-in and cart checks the labs ask you to run.

> ⚠️ These are throwaway credentials for a local sandbox, and the authentication behind them is deliberately insecure — salted SHA-1 password hashes. That is the "before" state the bootcamp migrates away from.