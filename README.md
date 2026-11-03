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
| `AZURE_CLIENT_ID` | Use this user-assigned managed identity (otherwise the system-assigned one) |
| `KeyVault__Uri` | Key Vault as a configuration source, e.g. a `ConnectionStrings--StoreDbContext` secret |
| `DataProtection__BlobUri` | Keep the sign-in/session key ring in a blob so it survives restarts and is shared by replicas |
| `DataProtection__KeyVaultKeyUri` | Also encrypt that key ring with a Key Vault key (needs `DataProtection__BlobUri`) |
| `DataProtection__ApplicationName` | Fixed app name so all replicas and revisions share keys |
| `Redis__Endpoint` | Keep session (the cart) in Azure Redis, e.g. `myredis.redis.cache.windows.net:6380` |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Send telemetry to Application Insights |
| `ASPNETCORE_FORWARDEDHEADERS_ENABLED` | `true` behind Container Apps ingress, so the app sees the original `https` scheme |

Container Apps probes: `/health` (liveness) and `/ready` (readiness). See [infra/](infra/README.md) for the Azure infrastructure (Bicep).

## Form security

Antiforgery validation is disabled application-wide, including login, logout, cart updates, and checkout. POST requests do not require an antiforgery token. Authentication, authorization, and form input validation remain enabled.

This removes CSRF protection from state-changing requests and is intended for the lab only, not production. Shared Data Protection keys are still required for authentication and session cookies across replicas and restarts.

# 🔑 Demo logins

The lab applications ship with seeded accounts. Whenever a module tells you to sign in, these are the credentials.

## Caldova storefront

| Username | Password | Role | Notes |
| --- | --- | --- | --- |
| `alice` | `Password1!` | Admin, Manager | Has existing order history |
| `bob` | `Password1!` | Employee | Has existing order history |

Either account works for the sign-in and cart checks the labs ask you to run.

> ⚠️ These are throwaway credentials for a local sandbox, and the authentication behind them is deliberately insecure — salted SHA-1 password hashes. That is the "before" state the bootcamp migrates away from.