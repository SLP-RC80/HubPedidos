using Microsoft.EntityFrameworkCore;
using Microsoft.AspNetCore.OutputCaching;

namespace HubPedidos.Relatorio7;

public sealed class AtualizadorPedidos(R7DbContext db, IEmissorPedido emissor, IOutputCacheStore cache)
{
    public async Task<ResultadoAtualizacao> AlterarAsync(Guid pedidoId, string usuario, string status,
        string? ifMatch, CancellationToken ct = default)
    {
        // Seguranca da propriedade verificada antes de devolver informacoes do recurso.
        var pedido = await db.Pedidos.SingleOrDefaultAsync(p => p.Id == pedidoId, ct);
        if (pedido is null) return new(404, Erro: "Pedido nao encontrado.");
        if (!string.Equals(pedido.Proprietario, usuario, StringComparison.Ordinal)) return new(403, Erro: "Sem acesso.");
        if (string.IsNullOrWhiteSpace(ifMatch)) return new(428, Erro: "If-Match obrigatorio.");
        if (!PedidoEtag.Corresponde(ifMatch, PedidoEtag.Calcular(pedido))) return new(412, Erro: "ETag obsoleta.");
        if (status is not ("Processando" or "Concluido")) return new(400, Erro: "Status invalido.");

        pedido.Status = status;
        pedido.Versao++;
        pedido.AtualizadoEm = DateTimeOffset.UtcNow;
        try
        {
            // A publicacao ocorre SOMENTE depois de persistir com sucesso.
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException)
        {
            return new(412, Erro: "Versao concorrente desatualizada.");
        }
        var evento = new PedidoAtualizado(pedido.Id, pedido.Status, pedido.Versao, pedido.AtualizadoEm);
        await emissor.EmitirAsync(evento, ct);
        await cache.EvictByTagAsync("catalogo-status", ct);
        return new(200, PedidoEtag.ParaDto(pedido));
    }
}
