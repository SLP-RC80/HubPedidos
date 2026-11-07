using HubPedidos.Application;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton(_ =>
    new CatalogoProcessadores(typeof(ProcessadorNormal).Assembly));

var app = builder.Build();
// Força a validação do catálogo uma única vez na inicialização.
_ = app.Services.GetRequiredService<CatalogoProcessadores>();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapPost("/api/pedidos/classificar", (
    CriarPedidoRequest request, CatalogoProcessadores catalogo) =>
{
    try
    {
        var pedido = PedidoMapper.ParaDominio(request);
        var categoria = ClassificadorPedido.Classificar(pedido);
        var processador = catalogo.Obter(categoria);
        var resposta = new PedidoResponse(
            pedido.Id.Valor, categoria, pedido.Total, processador.Executar(pedido));
        return Results.Ok(resposta);
    }
    catch (ArgumentException ex)
    {
        return Results.BadRequest(new { erro = ex.Message });
    }
});

app.Run();
public partial class Program { } // prepara WebApplicationFactory do roteiro 8
