using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Infrastructure;

public sealed class EnderecoEntrega
{
    public string Cidade { get; set; } = "";
    public string Uf { get; set; } = "";
}

public sealed class PedidoRegistro
{
    public Guid Id { get; set; }
    public string Status { get; set; } = "Pendente";
    public DateTime CriadoEm { get; set; }
    public decimal Total { get; set; }
    public EnderecoEntrega Endereco { get; set; } = new();
    public List<ItemPedidoRegistro> Itens { get; set; } = new();
}

public sealed class ItemPedidoRegistro
{
    public int Id { get; set; }
    public Guid PedidoId { get; set; }
    public PedidoRegistro Pedido { get; set; } = null!;
    public string Produto { get; set; } = "";
    public int Quantidade { get; set; }
    public decimal PrecoUnitario { get; set; }
}

// Mesmo conceito de endereco usado na tabela relacional, agora em coluna JSONB.
public sealed class PedidoJsonRegistro
{
    public Guid Id { get; set; }
    public string Status { get; set; } = "Pendente";
    public EnderecoEntrega Endereco { get; set; } = new();
}

public sealed class HubDbContext(DbContextOptions<HubDbContext> options) : DbContext(options)
{
    public DbSet<PedidoRegistro> Pedidos => Set<PedidoRegistro>();
    public DbSet<ItemPedidoRegistro> ItensPedido => Set<ItemPedidoRegistro>();
    public DbSet<PedidoJsonRegistro> PedidosJson => Set<PedidoJsonRegistro>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<PedidoRegistro>(e =>
        {
            e.ToTable("pedidos");
            e.HasKey(p => p.Id);
            e.Property(p => p.Status).HasMaxLength(32).IsRequired();
            e.Property(p => p.Total).HasPrecision(12, 2);
            e.HasIndex(p => new { p.Status, p.CriadoEm });
            // Representacao relacional: colunas Endereco_Cidade/Endereco_Uf.
            e.ComplexProperty(p => p.Endereco, a =>
            {
                a.Property(v => v.Cidade).HasMaxLength(80).IsRequired();
                a.Property(v => v.Uf).HasMaxLength(2).IsRequired();
            });
            e.HasMany(p => p.Itens).WithOne(i => i.Pedido)
                .HasForeignKey(i => i.PedidoId).OnDelete(DeleteBehavior.Cascade);
        });
        modelBuilder.Entity<ItemPedidoRegistro>(e =>
        {
            e.ToTable("itens_pedido");
            e.HasKey(i => i.Id);
            e.Property(i => i.Produto).HasMaxLength(100).IsRequired();
            e.Property(i => i.PrecoUnitario).HasPrecision(12, 2);
            e.HasIndex(i => i.PedidoId);
        });
        modelBuilder.Entity<PedidoJsonRegistro>(e =>
        {
            e.ToTable("pedidos_json");
            e.HasKey(p => p.Id);
            e.Property(p => p.Status).HasMaxLength(32).IsRequired();
            // EF Core 10 / Npgsql 10: tipo complexo armazenado em JSONB.
            e.ComplexProperty(p => p.Endereco, j => j.ToJson());
        });
    }
}
