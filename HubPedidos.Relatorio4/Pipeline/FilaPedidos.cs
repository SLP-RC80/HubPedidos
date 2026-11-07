using System.Threading.Channels;

namespace HubPedidos.Relatorio4.Pipeline;

public sealed class FilaPedidos(Channel<ProcessarPedidoJob> canal, MetricasFila metricas)
{
    private int _encerrado;
    public ChannelReader<ProcessarPedidoJob> Reader => canal.Reader;
    public void Concluir()
    {
        Interlocked.Exchange(ref _encerrado, 1);
        canal.Writer.TryComplete();
    }

    public ResultadoEnfileiramento TentarEnfileirar(ProcessarPedidoJob job)
    {
        if (Volatile.Read(ref _encerrado) != 0) return ResultadoEnfileiramento.Encerrado;
        if (!metricas.TentarRegistrar(job.PedidoId))
        {
            metricas.Duplicado();
            return ResultadoEnfileiramento.Duplicado;
        }
        var item = job with { EnfileiradoEm = DateTimeOffset.UtcNow };
        if (canal.Writer.TryWrite(item))
        {
            metricas.Aceito(canal.Reader.CanCount ? canal.Reader.Count : 0);
            return ResultadoEnfileiramento.Aceito;
        }
        metricas.DesfazerRegistro(job.PedidoId);
        metricas.Rejeitado();
        return Volatile.Read(ref _encerrado) != 0
            ? ResultadoEnfileiramento.Encerrado : ResultadoEnfileiramento.FilaCheia;
    }

    // Espera assincrona com backpressure, inclusive quando a fila esta cheia.
    public async ValueTask<ResultadoEnfileiramento> EnfileirarAguardandoAsync(
        ProcessarPedidoJob job, CancellationToken ct)
    {
        if (!metricas.TentarRegistrar(job.PedidoId))
        {
            metricas.Duplicado();
            return ResultadoEnfileiramento.Duplicado;
        }
        try
        {
            await canal.Writer.WriteAsync(job with { EnfileiradoEm = DateTimeOffset.UtcNow }, ct);
            metricas.Aceito(canal.Reader.CanCount ? canal.Reader.Count : 0);
            return ResultadoEnfileiramento.Aceito;
        }
        catch (ChannelClosedException)
        {
            metricas.DesfazerRegistro(job.PedidoId);
            return ResultadoEnfileiramento.Encerrado;
        }
        catch
        {
            metricas.DesfazerRegistro(job.PedidoId);
            throw;
        }
    }
}
