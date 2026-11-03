using System;
using System.Threading;
using System.Threading.Tasks;

using Azure.Core;

using eShopLite.StoreFx.Data;

using Xunit;

namespace eShopLite.StoreFx.Tests;

public class StoreDbConnectionTests
{
    [Fact]
    public void UsesAccessTokenInsteadOfUnsupportedConnectionStringAuthentication()
    {
        const string expectedToken = "test-access-token";
        var factory = new StoreDbConnectionFactory(
            "Server=tcp:sql.example,1433;Initial Catalog=eshop;User Id=runtime-client-id;Authentication=Active Directory Managed Identity;Encrypt=True;",
            new TestTokenCredential(expectedToken));

        using var connection = factory.CreateConnection();

        Assert.Equal(expectedToken, connection.AccessToken);
        Assert.DoesNotContain("Authentication", connection.ConnectionString, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("User Id", connection.ConnectionString, StringComparison.OrdinalIgnoreCase);
    }

    private sealed class TestTokenCredential : TokenCredential
    {
        private readonly string _token;

        public TestTokenCredential(string token)
        {
            _token = token;
        }

        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Assert.Equal("https://database.windows.net/.default", Assert.Single(requestContext.Scopes));
            return new AccessToken(_token, DateTimeOffset.UtcNow.AddHours(1));
        }

        public override ValueTask<AccessToken> GetTokenAsync(
            TokenRequestContext requestContext,
            CancellationToken cancellationToken)
        {
            return ValueTask.FromResult(GetToken(requestContext, cancellationToken));
        }
    }
}