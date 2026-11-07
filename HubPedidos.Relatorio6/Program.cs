using HubPedidos.Relatorio6;

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseDefaultServiceProvider((_, options) =>
{
    options.ValidateScopes = true;
    options.ValidateOnBuild = true;
});

builder.Services.AddOpenApi();
builder.Services.AddPedidosModule()
                .AddProcessamentoModule()
                .AddNotificacoesModule();
builder.Services.AddSingleton<ContadorUsoV1>();

var app = builder.Build();
app.MapOpenApi();
app.MapGet("/health", () => Results.Ok(new { status = "ok", modulo = "R6" }));

app.MapGet("/api/v1/pedidos/{id:guid}", ApiEndpoints.ObterV1)
    .WithName("ObterPedidoV1")
    .WithSummary("Obter pedido no contrato legado V1 (estavel)")
    .WithDescription("Compatibilidade mantida: id UUID, status string, total numero.")
    .Produces<PedidoV1Dto>(StatusCodes.Status200OK)
    .Produces(StatusCodes.Status404NotFound);

app.MapGet("/api/v2/pedidos/{id:guid}", ApiEndpoints.ObterV2)
    .WithName("ObterPedidoV2")
    .WithSummary("Obter pedido no contrato V2")
    .WithDescription("Mudanca intencional de contrato: situacao e total sao objetos.")
    .Produces<PedidoV2Dto>(StatusCodes.Status200OK)
    .Produces(StatusCodes.Status404NotFound);

app.MapGet("/api/metricas/versoes", (ContadorUsoV1 uso) =>
    Results.Ok(new { leiturasV1 = uso.Leituras }))
    .WithSummary("Telemetria de uso do contrato V1");

// Politica explicita de selecao: /api/pedidos/{id} e /api/v3/... nao sao mapeadas => 404.
app.Run();
