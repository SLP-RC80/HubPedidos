using System.Collections.Concurrent;
using System.Threading.Channels;

namespace HubPedidos.Relatorio4.Pipeline;

public sealed record ResumoFila(
    int Capacidade, int Consumidores, int LimiteBanco, int ProfundidadeAtual,
    int PicoFila, long Aceitos, long Processados, long Falhas,
    long Rejeitados, long Descartados, long Duplicados,
    int BancoEmExecucao, int PicoBanco, double EsperaMediaMs, double LatenciaMediaMs);

public sealed class MetricasFila
{
    private long _aceitos, _processados, _falhas, _rejeitados, _duplicados;
    private long _esperaTotalTicks, _latenciaTotalTicks;
    private int _picoFila, _bancoAtivo, _picoBanco;
    private readonly ConcurrentDictionary<Guid, EstadoPedido> _estados = new();

    public bool TentarRegistrar(Guid id) => _estados.TryAdd(id, EstadoPedido.EmFila);
    public void DesfazerRegistro(Guid id) => _estados.TryRemove(id, out _);
    public bool TentarObterEstado(Guid id, out EstadoPedido estado) => _estados.TryGetValue(id, out estado);
    public void Estado(Guid id, EstadoPedido estado) => _estados.AddOrUpdate(id, estado, (_, _) => estado);
    public void Aceito(int tamanhoFila) { Interlocked.Increment(ref _aceitos); Maximo(ref _picoFila, tamanhoFila); }
    public void Rejeitado() => Interlocked.Increment(ref _rejeitados);
    public void Duplicado() => Interlocked.Increment(ref _duplicados);
    public void IniciarBanco() => Maximo(ref _picoBanco, Interlocked.Increment(ref _bancoAtivo));
    public void FinalizarBanco() => Interlocked.Decrement(ref _bancoAtivo);

    public void Finalizado(bool sucesso, TimeSpan espera, TimeSpan latencia)
    {
        if (sucesso) Interlocked.Increment(ref _processados);
        else Interlocked.Increment(ref _falhas);
        Interlocked.Add(ref _esperaTotalTicks, espera.Ticks);
        Interlocked.Add(ref _latenciaTotalTicks, latencia.Ticks);
    }

    private static void Maximo(ref int campo, int valor)
    {
        int antigo;
        while ((antigo = Volatile.Read(ref campo)) < valor &&
               Interlocked.CompareExchange(ref campo, valor, antigo) != antigo) { }
    }

    public ResumoFila Resumo(ConfiguracaoFila c, Channel<ProcessarPedidoJob> canal)
    {
        var processados = Interlocked.Read(ref _processados);
        var falhas = Interlocked.Read(ref _falhas);
        var concluidos = processados + falhas;
        return new ResumoFila(c.Capacidade, c.Consumidores, c.LimiteBanco,
            canal.Reader.CanCount ? canal.Reader.Count : -1,
            Volatile.Read(ref _picoFila), Interlocked.Read(ref _aceitos),
            processados, falhas, Interlocked.Read(ref _rejeitados),
            0, // FullMode.Wait: nao ha descartes internos.
            Interlocked.Read(ref _duplicados), Volatile.Read(ref _bancoAtivo),
            Volatile.Read(ref _picoBanco),
            concluidos == 0 ? 0 : TimeSpan.FromTicks(Interlocked.Read(ref _esperaTotalTicks) / concluidos).TotalMilliseconds,
            concluidos == 0 ? 0 : TimeSpan.FromTicks(Interlocked.Read(ref _latenciaTotalTicks) / concluidos).TotalMilliseconds);
    }
}
