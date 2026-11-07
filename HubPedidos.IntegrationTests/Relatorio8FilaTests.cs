extern alias R4;
using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;
using FilaPedidos = R4::HubPedidos.Relatorio4.Pipeline.FilaPedidos;
using IPersistenciaPedido = R4::HubPedidos.Relatorio4.Pipeline.IPersistenciaPedido;
using ProcessarPedidoJob = R4::HubPedidos.Relatorio4.Pipeline.ProcessarPedidoJob;

namespace HubPedidos.IntegrationTests;

public sealed class Relatorio8FilaTests
{
    // Um TaskCompletionSource observa a persistencia fake sem sleeps arbitrarios.
    private sealed class PersistenciaObservada(TaskCompletionSource<Guid> concluido) : IPersistenciaPedido
    {
        public Task GravarAsync(ProcessarPedidoJob pedido, CancellationToken ct)
        {
            concluido.TrySetResult(pedido.PedidoId);
            return Task.CompletedTask;
        }
    }

    [Fact]
    public async Task R8_02_Fila_Post_Http_Executa_Consumidor_Com_Sinal_Deterministico()
    {
        var persistiu = new TaskCompletionSource<Guid>(TaskCreationOptions.RunContinuationsAsynchronously);
        // TEntryPoint esta no assembly da API R4; nao e necessario modificar Program.cs.
        using var fabrica = new WebApplicationFactory<FilaPedidos>().WithWebHostBuilder(builder =>
        {
            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<IPersistenciaPedido>();
                services.AddScoped<IPersistenciaPedido>(_ => new PersistenciaObservada(persistiu));
            });
        });
        using var cliente = fabrica.CreateClient();
        var id = Guid.NewGuid();
        using var resposta = await cliente.PostAsJsonAsync("/api/pipeline/enfileirar", new { pedidoId = id });
        Assert.Equal(HttpStatusCode.Accepted, resposta.StatusCode);
        // Sinal emitido pela persistencia fake, nao por Task.Delay.
        Assert.Equal(id, await persistiu.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        using var estado = await cliente.GetAsync($"/api/pipeline/status/{id:D}");
        Assert.Equal(HttpStatusCode.OK, estado.StatusCode);
    }
}
