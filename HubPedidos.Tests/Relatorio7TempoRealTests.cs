using HubPedidos.Relatorio7;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace HubPedidos.Tests;

public sealed class Relatorio7TempoRealTests
{
    private static PedidoPersistido Pedido(string status = "Processando", int versao = 1) =>
        new() { Id = ExemplosR7.AliceId, Proprietario = "alice", Regiao = "SP", Total = 80m,
            Status = status, Versao = versao, AtualizadoEm = new DateTimeOffset(2026, 11, 7, 12, 0, 0, TimeSpan.Zero) };

    [Fact] public void ETag_Estavel_Para_Mesmo_Conteudo() =>
        Assert.Equal(PedidoEtag.Calcular(Pedido()), PedidoEtag.Calcular(Pedido()));

    [Fact] public void ETag_Muda_Quando_Versao_Ou_Status_Mudam()
    {
        Assert.NotEqual(PedidoEtag.Calcular(Pedido()), PedidoEtag.Calcular(Pedido(versao: 2)));
        Assert.NotEqual(PedidoEtag.Calcular(Pedido()), PedidoEtag.Calcular(Pedido(status: "Concluido")));
    }

    [Fact] public void IfNoneMatch_Igual_E_Obsoleto_Sao_Distinguidos()
    {
        var tag = PedidoEtag.Calcular(Pedido());
        Assert.True(PedidoEtag.Corresponde(tag, tag));
        Assert.False(PedidoEtag.Corresponde("\"invalida\"", tag));
    }

    [Fact] public void Evento_Tipado_Nao_Expoe_Proprietario_Ou_Total()
    {
        var propriedades = typeof(PedidoAtualizado).GetProperties().Select(x => x.Name).ToArray();
        Assert.Equal(new[] { "PedidoId", "Status", "Versao", "Em" }, propriedades);
    }

    [Fact] public void DTO_Preserva_Versao_Apos_Persistencia()
    {
        var dto = PedidoEtag.ParaDto(Pedido(versao: 3));
        Assert.Equal(3, dto.Versao);
        Assert.Equal(80m, dto.Total);
    }

    [Fact] public void Grupo_SignalR_Escolhido_Pelo_Id_Do_Pedido() =>
        Assert.Equal($"pedido:{ExemplosR7.AliceId:D}", PedidosHub.Grupo(ExemplosR7.AliceId));

    [Fact] public async Task Autorizacao_Consulta_Propriedade_No_Banco()
    {
        var opts = new DbContextOptionsBuilder<R7DbContext>().UseSqlite("Data Source=:memory:").Options;
        await using var db = new R7DbContext(opts);
        await db.Database.OpenConnectionAsync();
        await db.Database.EnsureCreatedAsync();
        db.Pedidos.Add(Pedido());
        await db.SaveChangesAsync();
        var servico = new PedidoAccessService(db);
        Assert.True(await servico.PodeVerAsync("alice", ExemplosR7.AliceId));
        Assert.False(await servico.PodeVerAsync("bob", ExemplosR7.AliceId));
    }

    [Fact] public async Task Etag_Reflete_Mudanca_Persistida_Com_Concorrencia()
    {
        var opts = new DbContextOptionsBuilder<R7DbContext>().UseSqlite("Data Source=:memory:").Options;
        await using var db = new R7DbContext(opts);
        await db.Database.OpenConnectionAsync();
        await db.Database.EnsureCreatedAsync();
        db.Pedidos.Add(Pedido()); await db.SaveChangesAsync();
        var antes = PedidoEtag.Calcular((await db.Pedidos.SingleAsync()));
        var item = await db.Pedidos.SingleAsync();
        item.Status = "Concluido"; item.Versao++; item.AtualizadoEm = DateTimeOffset.UtcNow;
        await db.SaveChangesAsync();
        Assert.NotEqual(antes, PedidoEtag.Calcular(await db.Pedidos.SingleAsync()));
    }
}
