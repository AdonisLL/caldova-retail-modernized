using System;
using System.Threading;
using System.Threading.Tasks;

using eShopLite.StoreFx.Data;

using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Logging;

namespace eShopLite.StoreFx.Hosting
{
    public sealed class StoreDatabaseHealthCheck : IHealthCheck
    {
        private readonly StoreDbConnectionFactory _connectionFactory;
        private readonly ILogger<StoreDatabaseHealthCheck> _logger;

        public StoreDatabaseHealthCheck(
            StoreDbConnectionFactory connectionFactory,
            ILogger<StoreDatabaseHealthCheck> logger)
        {
            _connectionFactory = connectionFactory;
            _logger = logger;
        }

        public async Task<HealthCheckResult> CheckHealthAsync(
            HealthCheckContext context,
            CancellationToken cancellationToken = default)
        {
            try
            {
                using var connection = _connectionFactory.CreateConnection();
                await connection.OpenAsync(cancellationToken);
                using var command = connection.CreateCommand();
                command.CommandText = "SELECT 1";
                await command.ExecuteScalarAsync(cancellationToken);
                return HealthCheckResult.Healthy();
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                _logger.LogWarning(exception, "Store database readiness check failed.");
                return HealthCheckResult.Unhealthy("Store database connection failed.");
            }
        }
    }
}