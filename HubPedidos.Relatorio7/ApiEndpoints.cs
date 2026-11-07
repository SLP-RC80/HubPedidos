using System.Security.Claims;
using Microsoft.AspNetCore.OutputCaching;
using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Relatorio7;

public static class ApiEndpoints
{
    public static async Task<IResult> Detalhe(Guid id, HttpContext contexto, R7DbContext db, CancellationToken ct)
    {
        var usuario = contexto.User.FindFirstValue(ClaimTypes.NameIdentifier);
        var pedido = await db.Pedidos.AsNoTracking().SingleOrDefaultAsync(p => p.Id == id, ct);
        if (pedido is null) return Results.NotFound();
        if (usuario != pedido.Proprietario) return Results.Forbid();
        var etag = PedidoEtag.Calcular(pedido);
        contexto.Response.Headers.ETag = etag;
        contexto.Response.Headers.CacheControl = "private, no-cache";
        if (PedidoEtag.Corresponde(contexto.Request.Headers.IfNoneMatch, etag))
            return Results.StatusCode(StatusCodes.Status304NotModified); // sem corpo
        return Results.Ok(PedidoEtag.ParaDto(pedido));
    }

    public static async Task<IResult> Alterar(Guid id, AlterarStatusRequest pedido,
        HttpContext contexto, AtualizadorPedidos atualizador, CancellationToken ct)
    {
        var usuario = contexto.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (usuario is null) return Results.Unauthorized();
        var resultado = await atualizador.AlterarAsync(id, usuario, pedido.Status,
            contexto.Request.Headers.IfMatch.ToString(), ct);
        return resultado.HttpStatus switch
        {
            200 => Results.Ok(resultado.Pedido),
            400 => Results.BadRequest(new { erro = resultado.Erro }),
            403 => Results.Forbid(),
            404 => Results.NotFound(),
            412 => Results.StatusCode(StatusCodes.Status412PreconditionFailed),
            428 => Results.StatusCode(StatusCodes.Status428PreconditionRequired),
            _ => Results.StatusCode(resultado.HttpStatus)
        };
    }

    public static async Task<IResult> Catalogo(string? regiao, R7DbContext db, CancellationToken ct)
    {
        var dados = await db.Pedidos.AsNoTracking()
            .Where(p => regiao == null || p.Regiao == regiao.ToUpper())
            .Select(p => p.Status).ToListAsync(ct);
        var grupos = dados.GroupBy(x => x).OrderBy(x => x.Key)
            .Select(x => new { status = x.Key, quantidade = x.Count() }).ToArray();
        return Results.Ok(new { regiao = regiao?.ToUpper() ?? "TODAS", geradoEm = DateTimeOffset.UtcNow, status = grupos });
    }
}
