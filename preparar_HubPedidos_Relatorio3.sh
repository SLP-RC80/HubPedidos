#!/usr/bin/env bash
set -euo pipefail
cd /workspaces/HubPedidos
export PATH="$PATH:$HOME/.dotnet/tools"

echo '=== RELATORIO 3: PRE-CHECAGEM ==='
[[ "$(dotnet --version)" == 10.* ]] || { echo 'ERRO: SDK .NET 10 indisponivel.'; exit 1; }
[[ -f HubPedidos.sln && -f HubPedidos.Domain/Pedido.cs && -f HubPedidos.Application/ImportacaoLotes.cs ]] || { echo 'ERRO: versoes anteriores nao encontradas.'; exit 1; }
[[ "$(git branch --show-current)" == 'atividade-03-efcore' ]] || { echo 'ERRO: selecione a branch atividade-03-efcore.'; exit 1; }
for f in HubPedidos.Infrastructure/HubPedidos.Infrastructure.csproj HubPedidos.Relatorio3/HubPedidos.Relatorio3.csproj HubPedidos.Tests/Relatorio3DbTests.cs; do
  [[ ! -e "$f" ]] || { echo "ERRO: $f ja existe; nenhum arquivo foi sobrescrito."; exit 1; }
done
mkdir -p evidencias/relatorio3
if ! grep -qxF '.env.relatorio3' .gitignore; then printf '\n# Conexao de desenvolvimento Relatorio 3 - NAO VERSIONAR\n.env.relatorio3\n' >> .gitignore; fi

echo '=== Criando projetos de infraestrutura e exercicios EF Core ==='
dotnet new classlib -n HubPedidos.Infrastructure -f net10.0
dotnet new console -n HubPedidos.Relatorio3 -f net10.0
dotnet sln HubPedidos.sln add HubPedidos.Infrastructure/HubPedidos.Infrastructure.csproj HubPedidos.Relatorio3/HubPedidos.Relatorio3.csproj
dotnet add HubPedidos.Infrastructure/HubPedidos.Infrastructure.csproj package Npgsql.EntityFrameworkCore.PostgreSQL --version '10.*'
dotnet add HubPedidos.Infrastructure/HubPedidos.Infrastructure.csproj package Microsoft.EntityFrameworkCore.Design --version '10.*'
dotnet add HubPedidos.Relatorio3/HubPedidos.Relatorio3.csproj reference HubPedidos.Infrastructure/HubPedidos.Infrastructure.csproj
dotnet add HubPedidos.Relatorio3/HubPedidos.Relatorio3.csproj package Microsoft.EntityFrameworkCore.Design --version '10.*'
dotnet add HubPedidos.Tests/HubPedidos.Tests.csproj reference HubPedidos.Infrastructure/HubPedidos.Infrastructure.csproj
rm -f HubPedidos.Infrastructure/Class1.cs

cat > HubPedidos.Infrastructure/HubDbContext.cs <<'CS'
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
CS

cat > HubPedidos.Infrastructure/HubDbContextFactory.cs <<'CS'
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
CS

cat > HubPedidos.Infrastructure/ConsultasRelatorio3.cs <<'CS'
using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Infrastructure;

public sealed record PedidoResumoDto(
    Guid Id, string Status, DateTime CriadoEm, decimal Total, int QuantidadeItens);

public static class ConsultasRelatorio3
{
    public static IQueryable<PedidoResumoDto> Painel(HubDbContext db, string status)
        => db.Pedidos.AsNoTracking()
            .Where(p => p.Status == status)
            .OrderByDescending(p => p.CriadoEm).ThenBy(p => p.Id)
            .Select(p => new PedidoResumoDto(
                p.Id, p.Status, p.CriadoEm, p.Total, p.Itens.Count));

    public static IQueryable<PedidoResumoDto> Normal(HubDbContext db, string status)
        => Painel(db, status).Take(10);

    // Mesmo modelo, mesma projeção, somente parâmetros escalares.
    private static readonly Func<HubDbContext, string, IAsyncEnumerable<PedidoResumoDto>> ConsultaCompilada =
        EF.CompileAsyncQuery((HubDbContext db, string status) =>
            db.Pedidos.AsNoTracking()
                .Where(p => p.Status == status)
                .OrderByDescending(p => p.CriadoEm).ThenBy(p => p.Id)
                .Take(10)
                .Select(p => new PedidoResumoDto(
                    p.Id, p.Status, p.CriadoEm, p.Total, p.Itens.Count)));

    public static IAsyncEnumerable<PedidoResumoDto> Compilada(HubDbContext db, string status)
        => ConsultaCompilada(db, status);
}
CS

cat > HubPedidos.Infrastructure/SeedRelatorio3.cs <<'CS'
using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Infrastructure;

public static class SeedRelatorio3
{
    public static async Task PrepararAsync(HubDbContext db, CancellationToken ct = default)
    {
        if (!await db.Pedidos.AnyAsync(ct))
        {
            var dia = new DateTime(2026, 1, 10, 12, 0, 0, DateTimeKind.Utc);
            for (int i = 1; i <= 60; i++)
            {
                var itens = new List<ItemPedidoRegistro>
                {
                    new() { Produto = "Mouse", Quantidade = 1, PrecoUnitario = 29.90m },
                    new() { Produto = "Teclado", Quantidade = 2, PrecoUnitario = 59.90m }
                };
                db.Pedidos.Add(new PedidoRegistro
                {
                    Id = Guid.Parse($"00000000-0000-0000-0000-{i:D12}"),
                    Status = i % 3 == 0 ? "Concluido" : "Pendente",
                    CriadoEm = dia.AddMinutes(i),
                    Total = itens.Sum(x => x.Quantidade * x.PrecoUnitario),
                    Endereco = new EnderecoEntrega
                    {
                        Cidade = i % 2 == 0 ? "Sao Paulo" : "Campinas",
                        Uf = "SP"
                    },
                    Itens = itens
                });
            }
            await db.SaveChangesAsync(ct);
            db.ChangeTracker.Clear();
        }
        if (!await db.PedidosJson.AnyAsync(ct))
        {
            for (int i = 1; i <= 4; i++)
            {
                db.PedidosJson.Add(new PedidoJsonRegistro
                {
                    Id = Guid.Parse($"10000000-0000-0000-0000-{i:D12}"),
                    Status = "Pendente",
                    Endereco = new EnderecoEntrega { Cidade = "Sao Paulo", Uf = i == 4 ? "RJ" : "SP" }
                });
            }
            await db.SaveChangesAsync(ct);
            db.ChangeTracker.Clear();
        }
    }
}
CS

cat > HubPedidos.Infrastructure/ContadorComandos.cs <<'CS'
using System.Data.Common;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace HubPedidos.Infrastructure;

// Interceptor do EF: conta comandos efetivamente enviados, sem logar parâmetros sensíveis.
public sealed class ContadorComandos : DbCommandInterceptor
{
    private int _total;
    public int Total => Volatile.Read(ref _total);

    public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
        DbCommand command, CommandEventData eventData,
        InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref _total);
        return base.ReaderExecutingAsync(command, eventData, result, cancellationToken);
    }

    public override InterceptionResult<DbDataReader> ReaderExecuting(
        DbCommand command, CommandEventData eventData,
        InterceptionResult<DbDataReader> result)
    {
        Interlocked.Increment(ref _total);
        return base.ReaderExecuting(command, eventData, result);
    }
}
CS

cat > HubPedidos.Relatorio3/Program.cs <<'CS'
using HubPedidos.Relatorio3;

await Demonstracoes.ExecutarAsync(args);
CS

cat > HubPedidos.Relatorio3/Demonstracoes.cs <<'CS'
using System.Diagnostics;
using HubPedidos.Infrastructure;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using Microsoft.Extensions.Logging;

namespace HubPedidos.Relatorio3;

public static class Demonstracoes
{
    private static HubDbContext Abrir(ContadorComandos? contador = null, bool mostrarSql = false)
    {
        var conn = Environment.GetEnvironmentVariable("HUBPEDIDOS_DB");
        if (string.IsNullOrWhiteSpace(conn))
            throw new InvalidOperationException("HUBPEDIDOS_DB ausente. Execute: source .env.relatorio3");
        var builder = new DbContextOptionsBuilder<HubDbContext>().UseNpgsql(conn);
        if (contador is not null) builder.AddInterceptors(contador);
        if (mostrarSql)
            builder.LogTo(Console.WriteLine, new[] { RelationalEventId.CommandExecuted }, LogLevel.Information);
        return new HubDbContext(builder.Options);
    }

    public static async Task ExecutarAsync(string[] args)
    {
        var comando = args.FirstOrDefault()?.ToLowerInvariant() ?? "ajuda";
        switch (comando)
        {
            case "seed": await SeedAsync(); break;
            case "schema": await SchemaAsync(); break;
            case "sql": await SqlAsync(); break;
            case "painel": await PainelAsync(); break;
            case "tracking": await TrackingAsync(); break;
            case "compiled": await CompiledAsync(); break;
            case "json": await JsonAsync(); break;
            case "all":
                await SchemaAsync(); await SqlAsync(); await PainelAsync();
                await TrackingAsync(); await CompiledAsync(); await JsonAsync();
                break;
            default:
                Console.WriteLine("Comandos: seed | schema | sql | painel | tracking | compiled | json | all");
                break;
        }
    }

    private static async Task SeedAsync()
    {
        await using var db = Abrir();
        await SeedRelatorio3.PrepararAsync(db);
        Console.WriteLine("SEED OK: pedidos e itens/enderecos + amostra JSONB cadastrados de modo idempotente.");
    }

    private static async Task SchemaAsync()
    {
        await using var db = Abrir();
        var pendentes = await db.Database.GetPendingMigrationsAsync();
        Console.WriteLine($"R3.01 MIGRATIONS PENDENTES: {pendentes.Count()} (esperado: 0)");
        Console.WriteLine($"R3.01 TOTAL PEDIDOS: {await db.Pedidos.CountAsync()}");
        Console.WriteLine($"R3.01 TOTAL ITENS: {await db.ItensPedido.CountAsync()}");
        Console.WriteLine($"R3.01 TOTAL JSONB: {await db.PedidosJson.CountAsync()}");
    }

    private static async Task SqlAsync()
    {
        await using var db = Abrir(mostrarSql: true);
        Console.WriteLine("R3.02 SQL GERADO (ToQueryString, sem valores pessoais):");
        Console.WriteLine(ConsultasRelatorio3.Painel(db, "Pendente")
            .Skip(0).Take(10).ToQueryString());
        // Executar de fato para comprovar logging de comandos sem SensitiveDataLogging.
        _ = await ConsultasRelatorio3.Painel(db, "Pendente").Take(2).ToListAsync();
        Console.WriteLine("R3.04 SQL JSONB (filtro na propriedade complexa):");
        Console.WriteLine(db.PedidosJson.Where(p => p.Endereco.Uf == "SP")
            .Select(p => new { p.Id, p.Endereco.Cidade }).ToQueryString());
    }

    private static async Task PainelAsync()
    {
        var contador = new ContadorComandos();
        await using var db = Abrir(contador);
        var query = ConsultasRelatorio3.Painel(db, "Pendente");
        var total = await query.CountAsync();
        var pagina = await query.Skip(0).Take(10).ToListAsync();
        Console.WriteLine($"R3.02 PAINEL: total={total}, linhas_pagina={pagina.Count}, comandos_SQL={contador.Total}");
        foreach (var p in pagina.Take(3))
            Console.WriteLine($"  {p.Id}: {p.Status}; total={p.Total}; itens={p.QuantidadeItens}");
        Console.WriteLine($"R3.03 TRACKING no painel: {db.ChangeTracker.Entries<PedidoRegistro>().Count()} entidades (esperado: 0)");
        if (contador.Total != 2) throw new InvalidOperationException("Numero inesperado de comandos: investigar N+1.");
    }

    private static async Task TrackingAsync()
    {
        await using var db = Abrir();
        var pedido = await db.Pedidos.OrderBy(p => p.CriadoEm).FirstAsync();
        var anterior = pedido.Status;
        pedido.Status = "EmAnalise";
        Console.WriteLine($"R3.03 TRACKING: entidades antes do SaveChanges={db.ChangeTracker.Entries<PedidoRegistro>().Count()}");
        try
        {
            await db.SaveChangesAsync();
            await using var dbLeitura = Abrir();
            var statusConfirmado = await dbLeitura.Pedidos.AsNoTracking()
                .Where(p => p.Id == pedido.Id).Select(p => p.Status).SingleAsync();
            Console.WriteLine($"R3.03 ATUALIZACAO PERSISTIDA: {statusConfirmado}");
            if (statusConfirmado != "EmAnalise") throw new Exception("Falha ao persistir com tracking.");
        }
        finally
        {
            pedido.Status = anterior;
            await db.SaveChangesAsync();
        }
    }

    private static async Task CompiledAsync()
    {
        await using var db = Abrir();
        const int repeticoes = 30;
        var normalWarmup = await ConsultasRelatorio3.Normal(db, "Pendente").ToListAsync();
        var compiledWarmup = await ColetarCompiladaAsync(db);
        if (!normalWarmup.SequenceEqual(compiledWarmup))
            throw new InvalidOperationException("Consultas normal e compilada retornaram resultados diferentes.");

        var relogio = Stopwatch.StartNew();
        for (int i = 0; i < repeticoes; i++)
            _ = await ConsultasRelatorio3.Normal(db, "Pendente").ToListAsync();
        relogio.Stop();
        var tempoNormal = relogio.Elapsed.TotalMilliseconds;

        relogio.Restart();
        for (int i = 0; i < repeticoes; i++)
            _ = await ColetarCompiladaAsync(db);
        relogio.Stop();
        Console.WriteLine($"R3.04 CONSULTA NORMAL ({repeticoes} leituras): {tempoNormal:F2} ms");
        Console.WriteLine($"R3.04 CONSULTA COMPILADA ({repeticoes} leituras): {relogio.Elapsed.TotalMilliseconds:F2} ms");
        Console.WriteLine("R3.04 RESULTADOS EQUIVALENTES: sim; cronometro inclui banco/rede (nao e microbenchmark isolado).");
    }

    private static async Task<List<PedidoResumoDto>> ColetarCompiladaAsync(HubDbContext db)
    {
        var saida = new List<PedidoResumoDto>();
        await foreach (var p in ConsultasRelatorio3.Compilada(db, "Pendente")) saida.Add(p);
        return saida;
    }

    private static async Task JsonAsync()
    {
        await using var db = Abrir();
        var consulta = db.PedidosJson.AsNoTracking().Where(p => p.Endereco.Uf == "SP");
        Console.WriteLine($"R3.04 JSONB: registros filtrados UF=SP: {await consulta.CountAsync()}");
        var pedido = await db.PedidosJson.OrderBy(p => p.Id).FirstAsync();
        var cidadeAnterior = pedido.Endereco.Cidade;
        pedido.Endereco.Cidade = "Campinas";
        try
        {
            await db.SaveChangesAsync();
            await using var dbLeitura = Abrir();
            var confirmado = await dbLeitura.PedidosJson.AsNoTracking()
                .Where(p => p.Id == pedido.Id).Select(p => p.Endereco.Cidade).SingleAsync();
            Console.WriteLine($"R3.04 JSONB: cidade apos UPDATE: {confirmado}");
            if (confirmado != "Campinas") throw new Exception("Falha de atualizacao JSONB.");
        }
        finally
        {
            pedido.Endereco.Cidade = cidadeAnterior;
            await db.SaveChangesAsync();
        }
        Console.WriteLine("R3.04 JSONB: filtro e atualizacao verificados; valor original restaurado.");
    }
}
CS

cat > HubPedidos.Tests/Relatorio3DbTests.cs <<'CS'
using HubPedidos.Infrastructure;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace HubPedidos.Tests;

[CollectionDefinition("Relatorio3Banco", DisableParallelization = true)]
public sealed class Relatorio3BancoCollection { }

[Collection("Relatorio3Banco")]
public sealed class Relatorio3DbTests
{
    private static HubDbContext Abrir() => new HubDbContextFactory().CreateDbContext([]);

    [Fact]
    public async Task Migration_Esquema_Sem_Pendencias()
    {
        await using var db = Abrir();
        Assert.Empty(await db.Database.GetPendingMigrationsAsync());
        Assert.True(await db.Pedidos.CountAsync() > 0);
        Assert.True(await db.ItensPedido.CountAsync() > 0);
    }

    [Fact]
    public async Task Projecao_Paginada_E_Sem_Tracking()
    {
        await using var db = Abrir();
        var query = ConsultasRelatorio3.Painel(db, "Pendente").Skip(0).Take(10);
        var sql = query.ToQueryString();
        Assert.Contains("LIMIT", sql.ToUpperInvariant());
        var pagina = await query.ToListAsync();
        Assert.Equal(10, pagina.Count);
        Assert.Empty(db.ChangeTracker.Entries<PedidoRegistro>());
    }

    [Fact]
    public async Task Consulta_Painel_Nao_Produz_Nmais1()
    {
        var contador = new ContadorComandos();
        var cs = Environment.GetEnvironmentVariable("HUBPEDIDOS_DB")!;
        var opcoes = new DbContextOptionsBuilder<HubDbContext>()
            .UseNpgsql(cs).AddInterceptors(contador).Options;
        await using var db = new HubDbContext(opcoes);
        var query = ConsultasRelatorio3.Painel(db, "Pendente");
        var total = await query.CountAsync();
        var pagina = await query.Skip(0).Take(10).ToListAsync();
        Assert.True(total >= pagina.Count);
        Assert.Equal(2, contador.Total); // COUNT + SELECT projetado, sem consulta por item.
    }

    [Fact]
    public async Task Tracking_Atualiza_Entidade()
    {
        await using var db = Abrir();
        var registro = await db.Pedidos.OrderBy(p => p.CriadoEm).FirstAsync();
        var anterior = registro.Status;
        try
        {
            registro.Status = "EmAnalise";
            await db.SaveChangesAsync();
            await using var leitura = Abrir();
            var status = await leitura.Pedidos.AsNoTracking()
                .Where(p => p.Id == registro.Id).Select(p => p.Status).SingleAsync();
            Assert.Equal("EmAnalise", status);
        }
        finally
        {
            registro.Status = anterior;
            await db.SaveChangesAsync();
        }
    }

    [Fact]
    public async Task Consulta_Compilada_Equivale_Normal()
    {
        await using var db = Abrir();
        var normal = await ConsultasRelatorio3.Normal(db, "Pendente").ToListAsync();
        var compilada = new List<PedidoResumoDto>();
        await foreach (var p in ConsultasRelatorio3.Compilada(db, "Pendente")) compilada.Add(p);
        Assert.Equal(normal, compilada);
    }

    [Fact]
    public async Task Json_Filtra_E_Atualiza_Com_Restauracao()
    {
        await using var db = Abrir();
        var filtro = await db.PedidosJson.AsNoTracking()
            .Where(p => p.Endereco.Uf == "SP").CountAsync();
        Assert.True(filtro > 0);
        var pedido = await db.PedidosJson.OrderBy(p => p.Id).FirstAsync();
        var anterior = pedido.Endereco.Cidade;
        try
        {
            pedido.Endereco.Cidade = "Campinas";
            await db.SaveChangesAsync();
            await using var leitura = Abrir();
            var cidade = await leitura.PedidosJson.AsNoTracking()
                .Where(p => p.Id == pedido.Id).Select(p => p.Endereco.Cidade).SingleAsync();
            Assert.Equal("Campinas", cidade);
        }
        finally
        {
            pedido.Endereco.Cidade = anterior;
            await db.SaveChangesAsync();
        }
    }
}
CS

echo '=== Restaurando e compilando sem acessar o banco ==='
dotnet restore
dotnet build -c Release

echo '=== Arquivos adicionados; ainda falta banco, migration, seed e testes de BD ==='
echo 'Proximos passos: configurar PostgreSQL, criar migration, aplicar update, executar seed, demonstracoes e testes.'
