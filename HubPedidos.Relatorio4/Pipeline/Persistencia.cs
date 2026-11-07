using HubPedidos.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Relatorio4.Pipeline;

public interface IPersistenciaPedido
{
    Task GravarAsync(ProcessarPedidoJob pedido, CancellationToken ct);
}

// Persistencia didatica, para carga repetivel sem alterar o banco R3.
public sealed class PersistenciaSimulada(ConfiguracaoFila config) : IPersistenciaPedido
{
    public async Task GravarAsync(ProcessarPedidoJob pedido, CancellationToken ct)
    {
        await Task.Delay(config.AtrasoSimuladoMs, ct);
        if (pedido.PedidoId == Guid.Empty)
            throw new InvalidOperationException("Falha controlada em pedido de teste.");
    }
}

// Persistencia REAL no PostgreSQL; usa DbContext scoped e PK como protecao de duplicidade.
public sealed class PersistenciaPostgres(HubDbContext db) : IPersistenciaPedido
{
    public async Task GravarAsync(ProcessarPedidoJob pedido, CancellationToken ct)
    {
        if (await db.Pedidos.AnyAsync(p => p.Id == pedido.PedidoId, ct)) return;
        db.Pedidos.Add(new PedidoRegistro
        {
            Id = pedido.PedidoId,
            Status = "FilaR4",
            CriadoEm = DateTime.UtcNow,
            Total = 1m,
            Endereco = new EnderecoEntrega { Cidade = "Exercicio", Uf = "SP" },
            Itens = new List<ItemPedidoRegistro>()
        });
        await db.SaveChangesAsync(ct);
    }
}
