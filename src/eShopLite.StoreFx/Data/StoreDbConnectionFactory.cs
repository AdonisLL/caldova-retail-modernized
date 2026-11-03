using System;
using System.Data.Common;
using System.Data.SqlClient;
using System.Threading;

using Azure.Core;

namespace eShopLite.StoreFx.Data
{
    public sealed class StoreDbConnectionFactory
    {
        private const string SqlScope = "https://database.windows.net/.default";

        private readonly string _connectionString;
        private readonly TokenCredential _credential;

        public StoreDbConnectionFactory(string connectionString, TokenCredential credential)
        {
            _connectionString = connectionString ?? throw new ArgumentNullException(nameof(connectionString));
            _credential = credential ?? throw new ArgumentNullException(nameof(credential));
        }

        public SqlConnection CreateConnection()
        {
            var connectionParts = new DbConnectionStringBuilder { ConnectionString = _connectionString };
            connectionParts.Remove("Authentication");
            connectionParts.Remove("User ID");
            connectionParts.Remove("UID");
            connectionParts.Remove("User");
            connectionParts.Remove("Password");
            connectionParts.Remove("PWD");
            connectionParts.Remove("Integrated Security");
            connectionParts.Remove("Trusted_Connection");

            var connection = new SqlConnection(connectionParts.ConnectionString);
            try
            {
                var token = _credential.GetToken(
                    new TokenRequestContext(new[] { SqlScope }),
                    CancellationToken.None);
                connection.AccessToken = token.Token;
                return connection;
            }
            catch
            {
                connection.Dispose();
                throw;
            }
        }
    }
}