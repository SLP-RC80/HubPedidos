using HubPedidos.Modulos.Pedidos;

namespace HubPedidos.Relatorio6;

// V1 mantem tipos e nomes de campos: id, status (string) e total (numero).
public sealed record PedidoV1Dto(Guid Id, string Status, decimal Total);

// V2 altera intencionalmente os tipos; a mudanca NAO afeta a rota V1.
public sealed record SituacaoV2Dto(string Codigo, string Descricao);
public sealed record TotalV2Dto(decimal Valor, string Moeda);
public sealed record PedidoV2Dto(Guid Id, SituacaoV2Dto Situacao, TotalV2Dto Total);

public static class ContratosApi
{
    public static PedidoV1Dto ParaV1(PedidoInfo pedido) =>
        new(pedido.Id, pedido.Status, pedido.Total);

    public static PedidoV2Dto ParaV2(PedidoInfo pedido, string codigo, string descricao) =>
        new(pedido.Id, new SituacaoV2Dto(codigo, descricao), new TotalV2Dto(pedido.Total, "BRL"));
}

// Telemetria didatica de uso do contrato antigo, sem impor data arbitraria de remocao.
public sealed class ContadorUsoV1
{
    private long _leituras;
    public long Leituras => Interlocked.Read(ref _leituras);
    public void Registrar() => Interlocked.Increment(ref _leituras);
}
