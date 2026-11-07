using HubPedidos.Modulos.Pedidos;

namespace HubPedidos.Modulos.Notificacoes;

// Contrato de evento e apresentacao desacoplada do transporte de notificacoes.
public sealed record PedidoConsultado(Guid PedidoId, DateTimeOffset Em);

public interface INotificadorPedido
{
    string DescricaoSituacao(PedidoInfo pedido);
}

// Sem estado compartilhado mutavel: o registro singleton e seguro aqui.
public sealed class NotificadorPedido : INotificadorPedido
{
    public string DescricaoSituacao(PedidoInfo pedido) => pedido.Status switch
    {
        "Processando" => "Pedido em processamento",
        "Concluido" => "Pedido concluido",
        _ => "Situacao nao reconhecida"
    };
}
