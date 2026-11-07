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
