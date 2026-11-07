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
