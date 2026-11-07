using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Relatorio7;

public sealed class PedidoPersistido
{
    public Guid Id { get; set; }
    public string Proprietario { get; set; } = "";
    public string Regiao { get; set; } = "";
    public string Status { get; set; } = "";
    public decimal Total { get; set; }
    public int Versao { get; set; }
    public DateTimeOffset AtualizadoEm { get; set; }
}

public sealed class R7DbContext(DbContextOptions<R7DbContext> options) : DbContext(options)
{
    public DbSet<PedidoPersistido> Pedidos => Set<PedidoPersistido>();
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<PedidoPersistido>(b =>
        {
            b.HasKey(p => p.Id);
            b.Property(p => p.Versao).IsConcurrencyToken();
            b.Property(p => p.Status).HasMaxLength(48).IsRequired();
            b.Property(p => p.Proprietario).HasMaxLength(50).IsRequired();
            b.Property(p => p.Regiao).HasMaxLength(2).IsRequired();
        });
    }
}

public static class ExemplosR7
{
    public static readonly Guid AliceId = Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    public static readonly Guid BobId = Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
    public static void Semear(R7DbContext db)
    {
        db.Database.EnsureCreated();
        if (db.Pedidos.Any()) return;
        db.Pedidos.AddRange(
            new PedidoPersistido { Id = AliceId, Proprietario = "alice", Regiao = "SP", Status = "Processando", Total = 80.00m, Versao = 1, AtualizadoEm = DateTimeOffset.UtcNow },
            new PedidoPersistido { Id = BobId, Proprietario = "bob", Regiao = "RJ", Status = "Processando", Total = 50.00m, Versao = 1, AtualizadoEm = DateTimeOffset.UtcNow }
        );
        db.SaveChanges();
    }
}

public static class PedidoEtag
{
    // Hash da representacao completa relevante ao cliente. Uma mesma versao gera a mesma ETag.
    public static string Calcular(PedidoPersistido p)
    {
        var representacao = string.Join("|",
            p.Id.ToString("D"), p.Status, p.Total.ToString("0.00", CultureInfo.InvariantCulture),
            p.Versao.ToString(CultureInfo.InvariantCulture),
            p.AtualizadoEm.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));
        return "\"" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(representacao))) + "\"";
    }

    public static bool Corresponde(string? cabecalho, string atual) =>
        string.Equals(cabecalho?.Trim(), atual, StringComparison.Ordinal);

    public static PedidoDetalheDto ParaDto(PedidoPersistido p) =>
        new(p.Id, p.Status, p.Total, p.Versao, p.AtualizadoEm);
}
