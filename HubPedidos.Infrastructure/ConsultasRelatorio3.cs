using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Infrastructure;

public sealed record PedidoResumoDto(
    Guid Id, string Status, DateTime CriadoEm, decimal Total, int QuantidadeItens);

public static class ConsultasRelatorio3
{
    public static IQueryable<PedidoResumoDto> Painel(HubDbContext db, string status)
        => db.Pedidos.AsNoTracking()
            .Where(p => p.Status == status)
            .OrderByDescending(p => p.CriadoEm).ThenBy(p => p.Id)
            .Select(p => new PedidoResumoDto(
                p.Id, p.Status, p.CriadoEm, p.Total, p.Itens.Count));

    public static IQueryable<PedidoResumoDto> Normal(HubDbContext db, string status)
        => Painel(db, status).Take(10);

    // Mesmo modelo, mesma projeção, somente parâmetros escalares.
    private static readonly Func<HubDbContext, string, IAsyncEnumerable<PedidoResumoDto>> ConsultaCompilada =
        EF.CompileAsyncQuery((HubDbContext db, string status) =>
            db.Pedidos.AsNoTracking()
                .Where(p => p.Status == status)
                .OrderByDescending(p => p.CriadoEm).ThenBy(p => p.Id)
                .Take(10)
                .Select(p => new PedidoResumoDto(
                    p.Id, p.Status, p.CriadoEm, p.Total, p.Itens.Count)));

    public static IAsyncEnumerable<PedidoResumoDto> Compilada(HubDbContext db, string status)
        => ConsultaCompilada(db, status);
}
