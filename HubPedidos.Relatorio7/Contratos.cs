namespace HubPedidos.Relatorio7;

// Evento minimo, sem dados pessoais nem entidade de dominio.
public sealed record PedidoAtualizado(Guid PedidoId, string Status, int Versao, DateTimeOffset Em);

public interface IPedidosClient
{
    Task PedidoAtualizado(PedidoAtualizado evento);
}

public sealed record PedidoDetalheDto(Guid Id, string Status, decimal Total, int Versao, DateTimeOffset AtualizadoEm);
public sealed record AlterarStatusRequest(string Status);

public sealed record ResultadoAtualizacao(int HttpStatus, PedidoDetalheDto? Pedido = null, string? Erro = null);
