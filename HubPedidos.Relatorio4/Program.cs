using System.Threading.Channels;
using HubPedidos.Relatorio4.Pipeline;

var comando = args.FirstOrDefault()?.ToLowerInvariant();
if (comando is "cenarios" or "wait" or "shutdown" or "db")
{
    switch (comando)
    {
        case "cenarios": await Demonstracoes.CenáriosAsync(); break;
        case "wait": await Demonstracoes.EsperaAsync(); break;
        case "shutdown": await Demonstracoes.FalhaEShutdownAsync(); break;
        case "db": await Demonstracoes.BancoAsync(); break;
    }
    return;
}

int Numero(string nome, int fallback) => int.TryParse(Environment.GetEnvironmentVariable(nome), out var n) ? n : fallback;
var config = new ConfiguracaoFila(
    Numero("R4_CAPACIDADE", 2), Numero("R4_CONSUMIDORES", 1),
    Numero("R4_LIMITE_BANCO", 1), Numero("R4_ATRASO_MS", 350));

var builder = WebApplication.CreateBuilder(args);
builder.Services.AdicionarPipelineR4(config);
var app = builder.Build();
app.MapGet("/api/pipeline/metricas", (
    MetricasFila m, Channel<ProcessarPedidoJob> ch) => Results.Ok(m.Resumo(config, ch)));
app.MapGet("/api/pipeline/status/{id:guid}", (Guid id, MetricasFila m) =>
    m.TentarObterEstado(id, out var estado) ? Results.Ok(new { pedidoId = id, estado = estado.ToString() }) : Results.NotFound());
app.MapPost("/api/pipeline/enfileirar", (ProcessarPedidoJob pedido, FilaPedidos fila) =>
{
    if (pedido.PedidoId == Guid.Empty) return Results.BadRequest(new { erro = "PedidoId invalido." });
    return fila.TentarEnfileirar(pedido) switch
    {
        ResultadoEnfileiramento.Aceito => Results.Accepted($"/api/pipeline/status/{pedido.PedidoId}", new { pedidoId = pedido.PedidoId }),
        ResultadoEnfileiramento.Duplicado => Results.Conflict(new { erro = "Pedido ja registrado." }),
        ResultadoEnfileiramento.FilaCheia => Results.StatusCode(StatusCodes.Status429TooManyRequests),
        _ => Results.StatusCode(StatusCodes.Status503ServiceUnavailable)
    };
});
app.MapPost("/api/pipeline/enfileirar-esperando", async (
    ProcessarPedidoJob pedido, FilaPedidos fila, CancellationToken ct) =>
{
    if (pedido.PedidoId == Guid.Empty) return Results.BadRequest(new { erro = "PedidoId invalido." });
    var resultado = await fila.EnfileirarAguardandoAsync(pedido, ct);
    return resultado switch
    {
        ResultadoEnfileiramento.Aceito => Results.Accepted($"/api/pipeline/status/{pedido.PedidoId}"),
        ResultadoEnfileiramento.Duplicado => Results.Conflict(new { erro = "Pedido duplicado." }),
        _ => Results.StatusCode(StatusCodes.Status503ServiceUnavailable)
    };
});
app.Run();
