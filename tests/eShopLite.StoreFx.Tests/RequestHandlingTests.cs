using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http.Headers;
using System.Threading.Tasks;

using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

using eShopLite.StoreFx.Models;
using eShopLite.StoreFx.Services;

using Xunit;

namespace eShopLite.StoreFx.Tests;

public class RequestHandlingTests
{
    private const string FailureMarker = "synthetic-store-failure";

    [Theory]
    [InlineData("/")]
    [InlineData("/health")]
    [InlineData("/ready")]
    public async Task HeadProbesReturnSuccessWithoutDatabaseAccess(string path)
    {
        using var app = CreateApp("Production", null);
        using var client = app.CreateClient();
        using var request = new System.Net.Http.HttpRequestMessage(System.Net.Http.HttpMethod.Head, path);
        using var response = await client.SendAsync(request);

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        if (path == "/")
        {
            Assert.Empty(await response.Content.ReadAsByteArrayAsync());
        }
    }

    [Fact]
    public async Task GetHomeStillRendersHtml()
    {
        using var app = CreateApp("Production", null);
        using var client = app.CreateClient();
        using var response = await client.GetAsync("/");

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("text/html", response.Content.Headers.ContentType.MediaType);
        Assert.Contains("<html", await response.Content.ReadAsStringAsync());
    }

    [Theory]
    [InlineData("Production", null, false)]
    [InlineData("Production", "false", false)]
    [InlineData("Production", "true", true)]
    [InlineData("Development", null, true)]
    public async Task DetailedErrorsAreExplicitlyOptInOutsideDevelopment(
        string environment, string setting, bool showDetails)
    {
        using var app = CreateApp(environment, setting);
        using var client = app.CreateClient();
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("text/html"));
        using var response = await client.GetAsync("/Home/Stores");
        var html = await response.Content.ReadAsStringAsync();

        Assert.Equal(HttpStatusCode.InternalServerError, response.StatusCode);
        Assert.True(html.Contains(FailureMarker) == showDetails,
            "Exception details must be exposed only in Development or with explicit detailed-errors configuration.");
        if (!showDetails)
        {
            Assert.Contains("An error occurred while processing your request.", html);
        }
    }

    private static WebApplicationFactory<Program> CreateApp(string environment, string setting) =>
        new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment(environment);
            builder.UseSetting("ConnectionStrings:StoreDbContext",
                "Server=example.invalid;Initial Catalog=eshop;Integrated Security=True;Encrypt=True;");
            if (setting != null)
            {
                builder.UseSetting(WebHostDefaults.DetailedErrorsKey, setting);
            }
            builder.ConfigureServices(services =>
            {
                services.RemoveAll<IStoreService>();
                services.AddSingleton<IStoreService, FailingStoreService>();
            });
        });

    private sealed class FailingStoreService : IStoreService
    {
        public IEnumerable<Product> GetProducts() => throw new InvalidOperationException(FailureMarker);
        public IEnumerable<Product> SearchProducts(string searchTerm) => throw new InvalidOperationException(FailureMarker);
        public Product GetProduct(int id) => throw new InvalidOperationException(FailureMarker);
        public IEnumerable<StoreInfo> GetStores() => throw new InvalidOperationException(FailureMarker);
    }
}
