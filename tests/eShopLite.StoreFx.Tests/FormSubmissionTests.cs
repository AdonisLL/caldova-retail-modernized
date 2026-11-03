using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Threading.Tasks;

using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.Routing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

using eShopLite.StoreFx.Models;
using eShopLite.StoreFx.Services;

using Xunit;

namespace eShopLite.StoreFx.Tests;

public class FormSubmissionTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("invalid-token")]
    public async Task LoginAndLogout_DoNotRequireAntiforgeryValidation(string? token)
    {
        await using var factory = new StoreFactory();
        using var client = CreateClient(factory);

        using var response = await client.PostAsync("/Account/Login", LoginForm("test-password", token));

        Assert.Equal(HttpStatusCode.Redirect, response.StatusCode);
        Assert.Contains(response.Headers.GetValues("Set-Cookie"), value => value.StartsWith(".ESHOPLITEAUTH=", StringComparison.Ordinal));

        using var cart = await client.GetAsync("/Cart");
        Assert.Equal(HttpStatusCode.OK, cart.StatusCode);
        Assert.Contains("Hello, test-user!", await cart.Content.ReadAsStringAsync());

        using var logout = await client.PostAsync("/Account/Logout", new FormUrlEncodedContent(new Dictionary<string, string>()));
        Assert.Equal(HttpStatusCode.Redirect, logout.StatusCode);
        Assert.Equal("/", logout.Headers.Location?.OriginalString);

        using var checkout = await client.GetAsync("/Cart/Checkout");
        Assert.Equal(HttpStatusCode.Redirect, checkout.StatusCode);
        Assert.Contains("/Account/Login", checkout.Headers.Location?.OriginalString);
    }

    [Fact]
    public async Task InvalidCredentials_AreStillRejected()
    {
        await using var factory = new StoreFactory();
        using var client = CreateClient(factory);

        using var response = await client.PostAsync("/Account/Login", LoginForm("wrong-password", null));

        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Contains("Invalid user name or password.", await response.Content.ReadAsStringAsync());
        Assert.DoesNotContain(response.Headers.GetValues("Set-Cookie"), value => value.StartsWith(".ESHOPLITEAUTH=", StringComparison.Ordinal));
    }

    [Fact]
    public async Task CartForms_WithoutTokens_AddUpdateAndRemoveItems()
    {
        await using var factory = new StoreFactory();
        using var client = CreateClient(factory);

        using var add = await client.PostAsync("/Home/Products", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["_handler"] = "[product-1]add-to-cart",
            ["Quantity"] = "2"
        }));
        Assert.Equal(HttpStatusCode.Redirect, add.StatusCode);

        using var addedCart = await client.GetAsync("/Cart");
        Assert.Equal(HttpStatusCode.OK, addedCart.StatusCode);
        Assert.Contains("value=\"2\"", await addedCart.Content.ReadAsStringAsync());

        using var update = await client.PostAsync("/Cart", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["_handler"] = "[line-1]update-quantity",
            ["Quantity"] = "3"
        }));
        Assert.Equal(HttpStatusCode.Redirect, update.StatusCode);

        using var updatedCart = await client.GetAsync("/Cart");
        Assert.Equal(HttpStatusCode.OK, updatedCart.StatusCode);
        Assert.Contains("value=\"3\"", await updatedCart.Content.ReadAsStringAsync());

        using var remove = await client.PostAsync("/Cart", new FormUrlEncodedContent(new Dictionary<string, string>
        {
            ["_handler"] = "remove-1"
        }));
        Assert.Equal(HttpStatusCode.Redirect, remove.StatusCode);

        using var emptyCart = await client.GetAsync("/Cart");
        Assert.Equal(HttpStatusCode.OK, emptyCart.StatusCode);
        Assert.Contains("Your cart is empty.", await emptyCart.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task Logout_StillRequiresAuthentication()
    {
        await using var factory = new StoreFactory();
        using var client = CreateClient(factory);

        using var response = await client.PostAsync("/Account/Logout", new FormUrlEncodedContent(new Dictionary<string, string>()));

        Assert.Equal(HttpStatusCode.Redirect, response.StatusCode);
        Assert.Contains("/Account/Login", response.Headers.Location?.OriginalString);
    }

    [Fact]
    public void RazorEndpoints_DoNotRequireAntiforgeryValidation()
    {
        using var factory = new StoreFactory();
        using var client = CreateClient(factory);
        var endpoints = factory.Services.GetRequiredService<EndpointDataSource>().Endpoints;

        Assert.NotEmpty(endpoints);
        Assert.All(endpoints, endpoint =>
            Assert.False(endpoint.Metadata.GetMetadata<IAntiforgeryMetadata>()?.RequiresValidation ?? false));
    }

    private static HttpClient CreateClient(StoreFactory factory) =>
        factory.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = new Uri("https://localhost"),
            AllowAutoRedirect = false
        });

    private static FormUrlEncodedContent LoginForm(string password, string? token)
    {
        var fields = new Dictionary<string, string>
        {
            ["_handler"] = "login",
            ["Input.UserName"] = "test-user",
            ["Input.Password"] = password
        };
        if (token != null)
        {
            fields["__RequestVerificationToken"] = token;
        }

        return new FormUrlEncodedContent(fields);
    }

    private sealed class StoreFactory : WebApplicationFactory<Program>
    {
        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.UseEnvironment("Development");
            builder.ConfigureServices(services =>
            {
                services.RemoveAll<IAuthService>();
                services.AddSingleton<IAuthService, TestAuthService>();
                services.RemoveAll<IStoreService>();
                services.AddSingleton<IStoreService, TestStoreService>();
            });
        }
    }

    private sealed class TestAuthService : IAuthService
    {
        public User? ValidateUser(string userName, string password) =>
            userName == "test-user" && password == "test-password"
                ? new User { UserName = userName, Roles = "Employee" }
                : null;

        public string HashPassword(string password, string salt) => throw new NotSupportedException();
        public string CreateSalt() => throw new NotSupportedException();
    }

    private sealed class TestStoreService : IStoreService
    {
        private readonly Product _product = new Product
        {
            Id = 1,
            Name = "Test product",
            Description = "Test description",
            ImageUrl = "product1.png",
            Price = 10
        };

        public IEnumerable<Product> GetProducts() => new[] { _product };
        public IEnumerable<Product> SearchProducts(string searchTerm) => GetProducts();
        public Product? GetProduct(int id) => id == _product.Id ? _product : null;
        public IEnumerable<StoreInfo> GetStores() => Array.Empty<StoreInfo>();
    }
}
