using HubPedidos.Modulos.Pedidos;
using HubPedidos.Modulos.Processamento;
using HubPedidos.Modulos.Notificacoes;
using Microsoft.AspNetCore.Http;

namespace HubPedidos.Relatorio6;

public static class ApiEndpoints
{
    public static IResult ObterV1(Guid id, ConsultaPedidos pedidos, ContadorUsoV1 uso)
    {
        var pedido = pedidos.Obter(id);
        if (pedido is null) return Results.NotFound(new { erro = "Pedido nao encontrado." });
        uso.Registrar();
        return Results.Ok(ContratosApi.ParaV1(pedido));
    }

    public static IResult ObterV2(Guid id, ConsultaPedidos pedidos,
        IProcessadorPedido processamento, INotificadorPedido notificacoes)
    {
        var pedido = pedidos.Obter(id);
        if (pedido is null) return Results.NotFound(new { erro = "Pedido nao encontrado." });
        return Results.Ok(ContratosApi.ParaV2(
            pedido, processamento.CodigoSituacao(pedido), notificacoes.DescricaoSituacao(pedido)));
    }
}
