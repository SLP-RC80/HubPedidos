using System.Diagnostics;
using System.Threading.Channels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace HubPedidos.Relatorio4.Pipeline;

public sealed class ConsumidorPedidos(
    FilaPedidos fila, ConfiguracaoFila config, MetricasFila metricas,
    IServiceScopeFactory fabricaEscopos, SemaphoreSlim limiteBanco,
    ILogger<ConsumidorPedidos> logger) : BackgroundService
{
    private readonly CancellationTokenSource _abortarSeExcederPrazo = new();
    private readonly TaskCompletionSource<bool> _finalizou = new(TaskCreationOptions.RunContinuationsAsynchronously);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        try
        {
            // Multiplos leitores do mesmo Channel; cancelamento apenas no timeout de shutdown.
            var leitores = Enumerable.Range(1, config.Consumidores)
                .Select(i => ConsumirAsync(i, _abortarSeExcederPrazo.Token));
            await Task.WhenAll(leitores);
        }
        finally { _finalizou.TrySetResult(true); }
    }

    private async Task ConsumirAsync(int numero, CancellationToken ct)
    {
        await foreach (var job in fila.Reader.ReadAllAsync(ct))
        {
            var cronometro = Stopwatch.StartNew();
            var espera = DateTimeOffset.UtcNow - (job.EnfileiradoEm ?? DateTimeOffset.UtcNow);
            metricas.Estado(job.PedidoId, EstadoPedido.Processando);
            var sucesso = false;
            try
            {
                await using var scope = fabricaEscopos.CreateAsyncScope();
                var persistencia = scope.ServiceProvider.GetRequiredService<IPersistenciaPedido>();
                await limiteBanco.WaitAsync(ct);
                try
                {
                    metricas.IniciarBanco();
                    try { await persistencia.GravarAsync(job, ct); }
                    finally { metricas.FinalizarBanco(); }
                }
                finally { limiteBanco.Release(); }
                sucesso = true;
                metricas.Estado(job.PedidoId, EstadoPedido.Concluido);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                metricas.Estado(job.PedidoId, EstadoPedido.Falhou);
                throw;
            }
            catch (Exception ex)
            {
                metricas.Estado(job.PedidoId, EstadoPedido.Falhou);
                logger.LogWarning(ex, "R4 falha isolada pedido={PedidoId} consumidor={Numero}", job.PedidoId, numero);
            }
            finally
            {
                metricas.Finalizado(sucesso, espera, cronometro.Elapsed);
            }
        }
    }

    public override async Task StopAsync(CancellationToken cancellationToken)
    {
        fila.Concluir(); // encerra entrada, mas permite consumir itens ainda na fila.
        try { await _finalizou.Task.WaitAsync(cancellationToken); }
        catch (OperationCanceledException)
        {
            logger.LogWarning("R4: prazo de encerramento excedido; interrompendo trabalho pendente.");
            _abortarSeExcederPrazo.Cancel();
        }
        await base.StopAsync(cancellationToken);
    }

    public override void Dispose()
    {
        _abortarSeExcederPrazo.Dispose();
        base.Dispose();
    }
}
