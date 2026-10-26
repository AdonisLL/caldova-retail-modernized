using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Http;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;

using eShopLite.StoreFx.Models;
using eShopLite.StoreFx.Services;

using Xunit;

namespace eShopLite.StoreFx.Tests;

public class AntiforgeryTests
{
    [Theory]
    [InlineData(null, false, null)]
    [InlineData("false", false, null)]
    [InlineData("true", true, null)]
    [InlineData(null, false, "invalid-token")]
    [InlineData("false", false, "invalid-token")]
    [InlineData("true", true, "invalid-token")]
    public async Task LoginWithMissingOrInvalidTokenRequiresExplicitLabBypass(string setting, bool bypassed, string token)
    {
        using var app = CreateApp(setting);
        using var client = CreateClient(app);
        using var response = await client.PostAsync("/Account/Login", LoginForm(token));

        Assert.Equal(bypassed ? HttpStatusCode.Redirect : HttpStatusCode.BadRequest, response.StatusCode);
        if (bypassed)
        {
            Assert.Contains(response.Headers.GetValues("Set-Cookie"), cookie => cookie.StartsWith(".ESHOPLITEAUTH="));
        }
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LoginWithTokenAndLogoutRespectConfiguredMode(bool bypassed)
    {
        using var app = CreateApp(bypassed.ToString());
        using var client = CreateClient(app);
        var loginPage = await client.GetStringAsync("/Account/Login");
        using var login = await client.PostAsync("/Account/Login", LoginForm(ReadToken(loginPage)));
        Assert.Equal(HttpStatusCode.Redirect, login.StatusCode);

        using var logoutWithoutToken = await client.PostAsync("/Account/Logout", new FormUrlEncodedContent(
            new Dictionary<string, string>()));
        Assert.Equal(bypassed ? HttpStatusCode.Redirect : HttpStatusCode.BadRequest, logoutWithoutToken.StatusCode);

        if (!bypassed)
        {
            var home = await client.GetStringAsync("/");
            using var logoutWithToken = await client.PostAsync("/Account/Logout", new FormUrlEncodedContent(
                new Dictionary<string, string> { ["__RequestVerificationToken"] = ReadToken(home) }));
            Assert.Equal(HttpStatusCode.Redirect, logoutWithToken.StatusCode);
        }

        using var orders = await client.GetAsync("/Order");
        Assert.Equal(HttpStatusCode.Redirect, orders.StatusCode);
        Assert.Contains("/Account/Login", orders.Headers.Location.OriginalString);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task LabBypassDoesNotDisableAuthorization(bool bypassed)
    {
        using var app = CreateApp(bypassed.ToString());
        using var client = CreateClient(app);
        foreach (var path in new[] { "/Order", "/Account/Logout" })
        {
            using var response = path == "/Order"
                ? await client.GetAsync(path)
                : await client.PostAsync(path, new FormUrlEncodedContent(new Dictionary<string, string>()));
            Assert.Equal(HttpStatusCode.Redirect, response.StatusCode);
            Assert.Contains("/Account/Login", response.Headers.Location.OriginalString);
        }
    }

    private static WebApplicationFactory<Program> CreateApp(string setting)
    {
        return new WebApplicationFactory<Program>().WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment("Testing");
            builder.UseSetting("ConnectionStrings:StoreDbContext",
                "Server=example.invalid;Initial Catalog=eshop;Integrated Security=True;Encrypt=True;");
            if (setting != null)
            {
                builder.UseSetting("Lab06:DisableAntiforgery", setting);
            }
            builder.ConfigureServices(services =>
            {
                services.RemoveAll<IAuthService>();
                services.AddSingleton<IAuthService, TestAuthService>();
            });
        });
    }

    private static HttpClient CreateClient(WebApplicationFactory<Program> app) =>
        app.CreateClient(new WebApplicationFactoryClientOptions
        {
            BaseAddress = new Uri("https://localhost"),
            AllowAutoRedirect = false
        });

    private static FormUrlEncodedContent LoginForm(string token = null)
    {
        var fields = new Dictionary<string, string>
        {
            ["_handler"] = "login",
            ["Input.UserName"] = "test-user",
            ["Input.Password"] = "test-password"
        };
        if (token != null)
        {
            fields["__RequestVerificationToken"] = token;
        }
        return new FormUrlEncodedContent(fields);
    }

    private static string ReadToken(string html)
    {
        var match = Regex.Match(html, "name=\"__RequestVerificationToken\"[^>]*value=\"([^\"]+)\"");
        Assert.True(match.Success, "Expected a rendered antiforgery token.");
        return WebUtility.HtmlDecode(match.Groups[1].Value);
    }

    private sealed class TestAuthService : IAuthService
    {
        public User ValidateUser(string userName, string password) =>
            userName == "test-user" && password == "test-password"
                ? new User { UserName = "test-user", Roles = "Customer", IsApproved = true }
                : null;

        public string HashPassword(string password, string salt) => throw new NotSupportedException();
        public string CreateSalt() => throw new NotSupportedException();
    }
}
