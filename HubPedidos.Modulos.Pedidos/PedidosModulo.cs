using HubPedidos.Domain;

namespace HubPedidos.Modulos.Pedidos;

// Contratos do modulo: sem dependencia de ASP.NET Core, EF Core ou API.
public sealed record PedidoInfo(Guid Id, string Status, decimal Total);

public interface IRepositorioConsultaPedidos
{
    PedidoInfo? Obter(Guid id);
}

public static class PedidoExemplo
{
    public static readonly Guid Id = Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
}

// Adaptador em memoria: apenas para demonstracao arquitetural R6, sem alterar o Neon.
public sealed class RepositorioConsultaEmMemoria : IRepositorioConsultaPedidos
{
    private static readonly PedidoId IdTipado = PedidoId.Criar(PedidoExemplo.Id);

    public PedidoInfo? Obter(Guid id) => id == IdTipado.Valor
        ? new PedidoInfo(IdTipado.Valor, "Processando", 80.00m)
        : null;
}

// Servico scoped no modulo consumidor do contrato de repositorio.
public sealed class ConsultaPedidos(IRepositorioConsultaPedidos repositorio)
{
    public PedidoInfo? Obter(Guid id) => repositorio.Obter(id);
}
