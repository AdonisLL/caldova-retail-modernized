using System;

using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

using eShopLite.StoreFx.Components;
using eShopLite.StoreFx.Data;
using eShopLite.StoreFx.Hosting;
using eShopLite.StoreFx.Services;

var builder = WebApplication.CreateBuilder(args);

// Must run before anything reads configuration, so Key Vault secrets (if configured) win.
builder.AddAzureKeyVaultConfiguration();
builder.AddAzureMonitorTelemetry();

var disableAntiforgeryForLab = builder.Configuration.GetValue<bool>("Lab06:DisableAntiforgery");

// Static server rendering only: every page is rendered per HTTP request, so the request-scoped
// DbContext, cookie sign-in and ASP.NET Core session all keep working as they did under MVC.
builder.Services.AddRazorComponents();
builder.Services.AddCascadingAuthenticationState();

var connectionString = builder.Configuration.GetConnectionString("StoreDbContext");

// One context per request, so every service in a request shares a single unit of work.
builder.Services.AddScoped<IStoreDbContext>(_ => new StoreDbContext(connectionString));
builder.Services.AddTransient<ISessionStore, HttpContextSessionStore>();
builder.Services.AddTransient<IFlashMessages, SessionFlashMessages>();
builder.Services.AddTransient<IStoreService, StoreService>();
builder.Services.AddTransient<IAuthService, AuthService>();
builder.Services.AddTransient<ICartService, SessionCartService>();
builder.Services.AddTransient<IOrderService, OrderService>();

builder.Services.AddHttpContextAccessor();
builder.AddSessionCache();
builder.Services.AddSession(options =>
{
    options.IdleTimeout = TimeSpan.FromMinutes(30);
    options.Cookie.HttpOnly = true;
    options.Cookie.IsEssential = true;
});

builder.Services.AddAuthentication(CookieAuthenticationDefaults.AuthenticationScheme)
    .AddCookie(options =>
    {
        options.Cookie.Name = ".ESHOPLITEAUTH";
        options.LoginPath = "/Account/Login";
        options.ExpireTimeSpan = TimeSpan.FromMinutes(30);
        options.SlidingExpiration = true;
    });
builder.Services.AddAuthorization();
builder.AddDataProtectionKeyStore();

// Container Apps probes: /health = the process is up, /ready = checks tagged "ready" pass.
builder.Services.AddHealthChecks();

var app = builder.Build();

app.LogAzureIntegrations(builder);

if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Error", createScopeForErrors: true);
}

app.UseStatusCodePagesWithReExecute("/not-found", createScopeForStatusCodePages: true);

app.UseAuthentication();
app.UseAuthorization();
app.UseSession();
app.UseAntiforgery();

app.MapStaticAssets();
var componentEndpoints = app.MapRazorComponents<App>();
if (disableAntiforgeryForLab)
{
    componentEndpoints.DisableAntiforgery();
    app.Logger.LogWarning(
        "Lab06:DisableAntiforgery is enabled. CSRF protection is disabled for this deployment-only lab. Do not use this mode in production.");
}

app.MapHealthChecks("/health", new HealthCheckOptions { Predicate = _ => false });
app.MapHealthChecks("/ready", new HealthCheckOptions { Predicate = check => check.Tags.Contains("ready") });

// Signing out has no page of its own; the header's "Log out" button posts here. The endpoint binds
// no form fields, so the antiforgery token is checked explicitly outside deployment-only lab mode.
app.MapPost("/Account/Logout", async (HttpContext context, IAntiforgery antiforgery) =>
    {
        if (!disableAntiforgeryForLab && !await antiforgery.IsRequestValidAsync(context))
        {
            return Results.BadRequest();
        }

        await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
        context.Session.Clear();

        return Results.LocalRedirect("~/");
    })
    .RequireAuthorization();

app.Run();

public partial class Program { }
