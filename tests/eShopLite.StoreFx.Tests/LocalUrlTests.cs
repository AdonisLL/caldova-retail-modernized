using eShopLite.StoreFx.Components;
using Xunit;

namespace eShopLite.StoreFx.Tests;

public class LocalUrlTests
{
    [Theory]
    [InlineData("/")]
    [InlineData("/Products")]
    public void IsLocalAcceptsLocalPaths(string url)
    {
        Assert.True(LocalUrl.IsLocal(url));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("https://example.com")]
    [InlineData("//example.com")]
    [InlineData("/\\example.com")]
    [InlineData("/Products\n")]
    [InlineData("~/Products\r")]
    public void IsLocalRejectsUnsafePaths(string? url)
    {
        Assert.False(LocalUrl.IsLocal(url));
    }

    [Fact]
    public void OrHomeConvertsAppRelativePath()
    {
        Assert.Equal("/Products", LocalUrl.OrHome("~/Products"));
    }

    [Fact]
    public void OrHomeFallsBackForExternalUrl()
    {
        Assert.Equal("/", LocalUrl.OrHome("https://example.com"));
    }
}