using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;

namespace HubPedidos.Relatorio7;

// Grupo nao fornece seguranca: cada inscricao depende da autorizacao no servidor.
[Authorize]
public sealed class PedidosHub(IPedidoAccessService acesso, IHostEnvironment ambiente) : Hub<IPedidosClient>
{
    public async Task Acompanhar(Guid pedidoId)
    {
        var usuario = Context.UserIdentifier;
        if (usuario is null || !await acesso.PodeVerAsync(usuario, pedidoId, Context.ConnectionAborted))
            throw new HubException("Acesso nao autorizado ao pedido.");
        await Groups.AddToGroupAsync(Context.ConnectionId, Grupo(pedidoId));
    }

    // Apenas no ambiente Development: interrompe a conexao para testar reconexao/reingresso.
    public void SimularQueda()
    {
        if (!ambiente.IsDevelopment()) throw new HubException("Indisponivel fora de Development.");
        Context.Abort();
    }

    public static string Grupo(Guid id) => $"pedido:{id:D}";
}

public interface IEmissorPedido
{
    Task EmitirAsync(PedidoAtualizado evento, CancellationToken ct = default);
}

public sealed class EmissorSignalR(IHubContext<PedidosHub, IPedidosClient> hub) : IEmissorPedido
{
    public Task EmitirAsync(PedidoAtualizado evento, CancellationToken ct = default) =>
        hub.Clients.Group(PedidosHub.Grupo(evento.PedidoId)).PedidoAtualizado(evento);
}
