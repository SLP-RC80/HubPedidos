using HubPedidos.Modulos.Pedidos;

namespace HubPedidos.Modulos.Processamento;

public interface IProcessadorPedido
{
    string CodigoSituacao(PedidoInfo pedido);
}

// Adaptador sem estado: pode ser registrado como transient.
public sealed class ProcessadorPedido : IProcessadorPedido
{
    public string CodigoSituacao(PedidoInfo pedido) => pedido.Status switch
    {
        "Processando" => "EM_PROCESSAMENTO",
        "Concluido" => "CONCLUIDO",
        _ => "DESCONHECIDO"
    };
}
