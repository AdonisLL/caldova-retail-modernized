using System.Data.Entity;
using System.Data.Entity.ModelConfiguration.Conventions;
using System.Data.Entity.SqlServer;
using System.Linq;

using Microsoft.Data.SqlClient;

using eShopLite.StoreFx.Models;

namespace eShopLite.StoreFx.Data
{
    public interface IStoreDbContext
    {
        DbSet<Product> Products { get; set; }
        DbSet<StoreInfo> Stores { get; set; }
        DbSet<User> Users { get; set; }
        DbSet<Order> Orders { get; set; }
        DbSet<OrderLine> OrderLines { get; set; }

        OrderSummary GetOrderSummary(int userId);

        int SaveChanges();
    }

    // Replaces the <entityFramework> section of the old Web.config, which .NET 10 never reads.
    public class StoreDbConfiguration : MicrosoftSqlDbConfiguration
    {
        public StoreDbConfiguration()
        {
            // The SQL schema scripts are the source of truth; EF must never alter the database.
            SetDatabaseInitializer<StoreDbContext>(null);
        }
    }

    [DbConfigurationType(typeof(StoreDbConfiguration))]
    public class StoreDbContext : DbContext, IStoreDbContext
    {
        public StoreDbContext() : base("StoreDbContext")
        {
        }

        public StoreDbContext(string nameOrConnectionString) : base(nameOrConnectionString)
        {
        }

        public DbSet<Product> Products { get; set; }
        public DbSet<StoreInfo> Stores { get; set; }
        public DbSet<User> Users { get; set; }
        public DbSet<Order> Orders { get; set; }
        public DbSet<OrderLine> OrderLines { get; set; }

        public OrderSummary GetOrderSummary(int userId)
        {
            // [Order] is a reserved word; COUNT(*) guarantees exactly one row even with no orders.
            const string sql =
                "SELECT COUNT(*) AS OrderCount, ISNULL(SUM(Total), 0) AS LifetimeTotal, " +
                "MIN(PlacedUtc) AS FirstOrderUtc, MAX(PlacedUtc) AS LastOrderUtc " +
                "FROM [Order] WHERE UserId = @userId";

            return Database
                .SqlQuery<OrderSummary>(sql, new SqlParameter("@userId", userId))
                .Single();
        }

        protected override void OnModelCreating(DbModelBuilder modelBuilder)
        {
            modelBuilder.Conventions.Remove<PluralizingTableNameConvention>();

            modelBuilder.Entity<User>()
                .HasIndex(u => u.UserName)
                .IsUnique();

            modelBuilder.Entity<Order>()
                .HasMany(o => o.Lines)
                .WithRequired(l => l.Order)
                .HasForeignKey(l => l.OrderId)
                .WillCascadeOnDelete(true);
        }
    }
}
