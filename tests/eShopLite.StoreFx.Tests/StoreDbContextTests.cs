using System.Data.Common;
using System.Data.Entity.Core.Common;

using eShopLite.StoreFx.Data;

using Xunit;

namespace eShopLite.StoreFx.Tests
{
    public class StoreDbContextTests
    {
        [Theory]
        [InlineData("Authentication=Active Directory Managed Identity;User Id=11111111-1111-1111-1111-111111111111;")]
        [InlineData("Authentication=Active Directory Default;")]
        [InlineData("User Id=test;Password=synthetic-test-password;")]
        [InlineData("Integrated Security=True;")]
        public void UsesModernSqlProviderWithoutOpeningConnection(string authentication)
        {
            using var context = new StoreDbContext(
                "Server=tcp:example.invalid,1433;Initial Catalog=eshop;" +
                "Encrypt=True;TrustServerCertificate=False;" + authentication);

            var connection = context.Database.Connection;
            Assert.Equal("Microsoft.Data.SqlClient.SqlConnection", connection.GetType().FullName);
            Assert.Equal(System.Data.ConnectionState.Closed, connection.State);

            var settings = new DbConnectionStringBuilder { ConnectionString = connection.ConnectionString };
            Assert.Equal("eshop", settings["Initial Catalog"]);
            Assert.Equal("True", settings["Encrypt"].ToString(), ignoreCase: true);
            Assert.Equal("False", settings["TrustServerCertificate"].ToString(), ignoreCase: true);
        }

        [Fact]
        public void RegistersMatchingEfProviderAndParameterFactory()
        {
            using var context = new StoreDbContext(
                "Server=example.invalid;Initial Catalog=eshop;Integrated Security=True;");
            var connection = context.Database.Connection;

            Assert.Equal(
                "System.Data.Entity.SqlServer.MicrosoftSqlProviderServices",
                DbProviderServices.GetProviderServices(connection).GetType().FullName);

            var factory = DbProviderFactories.GetFactory(connection);
            Assert.Equal("Microsoft.Data.SqlClient.SqlParameter", factory.CreateParameter().GetType().FullName);
        }
    }
}
