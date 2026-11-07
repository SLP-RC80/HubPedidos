using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Design;

namespace HubPedidos.Infrastructure;

public sealed class HubDbContextFactory : IDesignTimeDbContextFactory<HubDbContext>
{
    public HubDbContext CreateDbContext(string[] args)
    {
        var connectionString = Environment.GetEnvironmentVariable("HUBPEDIDOS_DB");
        if (string.IsNullOrWhiteSpace(connectionString))
            throw new InvalidOperationException("Configure HUBPEDIDOS_DB no ambiente (nao grave senhas no codigo).");
        var options = new DbContextOptionsBuilder<HubDbContext>()
            .UseNpgsql(connectionString).Options;
        return new HubDbContext(options);
    }
}
