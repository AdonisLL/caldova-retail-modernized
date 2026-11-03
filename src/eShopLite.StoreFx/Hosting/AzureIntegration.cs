using System;
using System.Collections.Generic;

using Azure.Core;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;

using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using OpenTelemetry.Instrumentation.AspNetCore;

using StackExchange.Redis;

namespace eShopLite.StoreFx.Hosting
{
    /// <summary>
    /// Opt-in Azure integrations. Each one turns on only when its setting is present in configuration;
    /// otherwise the app keeps its local behavior, so it builds and runs with no Azure resources.
    /// </summary>
    public static class AzureIntegration
    {
        private const string EnabledFeaturesKey = "eShopLite.AzureFeatures";

        /// <summary>
        /// One credential shared by every Azure client. Managed identity when running in Azure (the
        /// user-assigned one named by AZURE_CLIENT_ID, if set); developer sign-in (Azure CLI, Visual
        /// Studio, ...) in Development. Created only when some Azure feature is configured.
        /// </summary>
        public static TokenCredential GetAzureCredential(this IHostApplicationBuilder builder)
        {
            if (builder.Properties.TryGetValue(typeof(TokenCredential), out var cached))
            {
                return (TokenCredential)cached;
            }

            var clientId = builder.Configuration["AZURE_CLIENT_ID"];
            var hasClientId = !string.IsNullOrWhiteSpace(clientId);

            TokenCredential credential = builder.Environment.IsDevelopment()
                ? new DefaultAzureCredential(new DefaultAzureCredentialOptions { ManagedIdentityClientId = hasClientId ? clientId : null })
                : new ManagedIdentityCredential(hasClientId
                    ? ManagedIdentityId.FromUserAssignedClientId(clientId)
                    : ManagedIdentityId.SystemAssigned);

            builder.Properties[typeof(TokenCredential)] = credential;

            return credential;
        }

        /// <summary>
        /// KeyVault:Uri — adds Key Vault as a configuration source, so secrets such as
        /// "ConnectionStrings--StoreDbContext" override appsettings.json and environment variables.
        /// </summary>
        public static IHostApplicationBuilder AddAzureKeyVaultConfiguration(this IHostApplicationBuilder builder)
        {
            var vaultUri = GetOptionalUri(builder.Configuration, "KeyVault:Uri");
            if (vaultUri == null)
            {
                return builder;
            }

            builder.Configuration.AddAzureKeyVault(vaultUri, builder.GetAzureCredential());
            builder.RecordFeature($"Key Vault configuration source ({vaultUri.Host})");

            return builder;
        }

        /// <summary>
        /// Where the Data Protection key ring lives. Those keys protect the auth and session cookies,
        /// so in containers they must outlive a restart and be shared by replicas.
        /// DataProtection:BlobUri persists them to a blob; DataProtection:KeyVaultKeyUri additionally wraps
        /// them with a Key Vault key; DataProtection:ApplicationName pins the app discriminator. With none
        /// set, ASP.NET Core's default (local) key ring is used, exactly as before.
        /// </summary>
        public static IHostApplicationBuilder AddDataProtectionKeyStore(this IHostApplicationBuilder builder)
        {
            var dataProtection = builder.Services.AddDataProtection();

            var applicationName = builder.Configuration["DataProtection:ApplicationName"];
            if (!string.IsNullOrWhiteSpace(applicationName))
            {
                dataProtection.SetApplicationName(applicationName);
            }

            var blobUri = GetOptionalUri(builder.Configuration, "DataProtection:BlobUri");
            var keyUri = GetOptionalUri(builder.Configuration, "DataProtection:KeyVaultKeyUri");

            if (blobUri == null)
            {
                if (keyUri != null)
                {
                    // Wrapping keys that are then thrown away on restart would silently not help.
                    throw new InvalidOperationException(
                        "'DataProtection:KeyVaultKeyUri' requires 'DataProtection:BlobUri' to be set as well.");
                }

                return builder;
            }

            var credential = builder.GetAzureCredential();
            dataProtection.PersistKeysToAzureBlobStorage(blobUri, credential);

            if (keyUri != null)
            {
                dataProtection.ProtectKeysWithAzureKeyVault(keyUri, credential);
                builder.RecordFeature($"Data Protection keys in Blob Storage ({blobUri.Host}), wrapped by Key Vault ({keyUri.Host})");
            }
            else
            {
                builder.RecordFeature($"Data Protection keys in Blob Storage ({blobUri.Host})");
            }

            return builder;
        }

        /// <summary>
        /// The cache behind ASP.NET Core session (the cart). Redis:Endpoint (host:port of Azure Managed
        /// Redis or Azure Cache for Redis) switches to Redis with Microsoft Entra ID auth, so carts survive
        /// restarts and are shared by replicas. Without it, the in-memory cache is used as before.
        /// </summary>
        public static IHostApplicationBuilder AddSessionCache(this IHostApplicationBuilder builder)
        {
            var endpoint = builder.Configuration["Redis:Endpoint"];
            if (string.IsNullOrWhiteSpace(endpoint))
            {
                builder.Services.AddDistributedMemoryCache();
                return builder;
            }

            var credential = builder.GetAzureCredential();

            builder.Services.AddStackExchangeRedisCache(options =>
            {
                options.InstanceName = "eShopLite:";
                options.ConnectionMultiplexerFactory = async () =>
                {
                    // TLS is switched on automatically for Azure Redis host names.
                    var redisOptions = ConfigurationOptions.Parse(endpoint);
                    await redisOptions.ConfigureForAzureWithTokenCredentialAsync(credential);

                    return await ConnectionMultiplexer.ConnectAsync(redisOptions);
                };
            });

            builder.RecordFeature($"Redis session cache ({endpoint.Split(':')[0]})");

            return builder;
        }

        /// <summary>
        /// APPLICATIONINSIGHTS_CONNECTION_STRING — sends traces, metrics and logs to Application Insights
        /// through the Azure Monitor OpenTelemetry distro. Health-probe requests are left out so they
        /// don't drown real traffic. Without it, logging stays console-only as before.
        /// </summary>
        public static IHostApplicationBuilder AddAzureMonitorTelemetry(this IHostApplicationBuilder builder)
        {
            if (string.IsNullOrWhiteSpace(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
            {
                return builder;
            }

            builder.Services.AddOpenTelemetry().UseAzureMonitor();
            builder.Services.Configure<AspNetCoreTraceInstrumentationOptions>(options =>
                options.Filter = context =>
                    !context.Request.Path.StartsWithSegments("/health") &&
                    !context.Request.Path.StartsWithSegments("/ready"));

            builder.RecordFeature("Application Insights telemetry (Azure Monitor OpenTelemetry)");

            return builder;
        }

        /// <summary>Logs which Azure integrations are active, so a misconfigured deployment is easy to spot.</summary>
        public static void LogAzureIntegrations(this WebApplication app, IHostApplicationBuilder builder)
        {
            var features = builder.Properties.TryGetValue(EnabledFeaturesKey, out var value)
                ? (List<string>)value
                : new List<string>();

            if (features.Count == 0)
            {
                app.Logger.LogInformation("Azure integrations: none configured; using local defaults.");
                return;
            }

            foreach (var feature in features)
            {
                app.Logger.LogInformation("Azure integration enabled: {Feature}", feature);
            }
        }

        private static void RecordFeature(this IHostApplicationBuilder builder, string feature)
        {
            if (!builder.Properties.TryGetValue(EnabledFeaturesKey, out var value))
            {
                value = new List<string>();
                builder.Properties[EnabledFeaturesKey] = value;
            }

            ((List<string>)value).Add(feature);
        }

        private static Uri GetOptionalUri(IConfiguration configuration, string key)
        {
            var value = configuration[key];
            if (string.IsNullOrWhiteSpace(value))
            {
                return null;
            }

            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri))
            {
                throw new InvalidOperationException($"Configuration value '{key}' must be an absolute URI.");
            }

            return uri;
        }
    }
}
