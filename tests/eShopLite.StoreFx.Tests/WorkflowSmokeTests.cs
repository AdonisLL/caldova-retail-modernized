using Xunit;

namespace eShopLite.StoreFx.Tests;

public class WorkflowSmokeTests
{
    [Fact]
    public void TestRunner_CanExecuteAssertions()
    {
        Assert.Equal(4, 2 + 2);
    }
}
