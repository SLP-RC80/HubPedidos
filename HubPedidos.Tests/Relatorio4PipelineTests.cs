using System.Threading.Channels;
using HubPedidos.Relatorio4.Pipeline;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Xunit;

namespace HubPedidos.Tests;

public sealed class Relatorio4PipelineTests
{
    [Fact]
    public async Task ModoWait_ProdutorAguardaSemDescartar()
    {
        var canal = Channel.CreateBounded<int>(new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.Wait
        });
        await canal.Writer.WriteAsync(1);
        var esperando = canal.Writer.WriteAsync(2).AsTask();
        await Task.Delay(70);
        Assert.False(esperando.IsCompleted);
        Assert.Equal(1, await canal.Reader.ReadAsync());
        await esperando.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Equal(2, await canal.Reader.ReadAsync());
    }

    [Fact]
    public void TryWrite_FilaCheia_RejeitaSemDescartar()
    {
        var canal = Channel.CreateBounded<ProcessarPedidoJob>(new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.Wait
        });
        var metricas = new MetricasFila();
        var fila = new FilaPedidos(canal, metricas);
        Assert.Equal(ResultadoEnfileiramento.Aceito, fila.TentarEnfileirar(new(Guid.NewGuid())));
        Assert.Equal(ResultadoEnfileiramento.FilaCheia, fila.TentarEnfileirar(new(Guid.NewGuid())));
        var res = metricas.Resumo(new(1, 1, 1), canal);
        Assert.Equal(1, res.Aceitos);
        Assert.Equal(1, res.Rejeitados);
        Assert.Equal(0, res.Descartados);
    }

    [Fact]
    public async Task Espera_Cancelada_NaoDeixa_RegistroReservado()
    {
        var canal = Channel.CreateBounded<ProcessarPedidoJob>(new BoundedChannelOptions(1)
        {
            FullMode = BoundedChannelFullMode.Wait
        });
        var fila = new FilaPedidos(canal, new MetricasFila());
        _ = fila.TentarEnfileirar(new(Guid.NewGuid()));
        var id = Guid.NewGuid();
        using var cts = new CancellationTokenSource(TimeSpan.FromMilliseconds(80));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(async () =>
        {
            _ = await fila.EnfileirarAguardandoAsync(new(id), cts.Token);
        });
        Assert.Equal(1, canal.Reader.Count);
        Assert.Equal(ResultadoEnfileiramento.FilaCheia, fila.TentarEnfileirar(new(id)));
    }

    [Fact]
    public void Idempotencia_IdentificadorRepetidoNaoEntraDuasVezes()
    {
        var canal = Channel.CreateBounded<ProcessarPedidoJob>(2);
        var fila = new FilaPedidos(canal, new MetricasFila());
        var id = Guid.NewGuid();
        Assert.Equal(ResultadoEnfileiramento.Aceito, fila.TentarEnfileirar(new(id)));
        Assert.Equal(ResultadoEnfileiramento.Duplicado, fila.TentarEnfileirar(new(id)));
        Assert.Equal(1, canal.Reader.Count);
    }

    [Fact]
    public void Fechamento_RecusaNovasEntradas()
    {
        var canal = Channel.CreateBounded<ProcessarPedidoJob>(2);
        var fila = new FilaPedidos(canal, new MetricasFila());
        fila.Concluir();
        Assert.Equal(ResultadoEnfileiramento.Encerrado, fila.TentarEnfileirar(new(Guid.NewGuid())));
    }

    [Fact]
    public async Task Falha_De_Item_NaoInterrompe_Os_Demais_E_Shutdown_Drena()
    {
        var c = new ConfiguracaoFila(4, 3, 2, 8);
        using var host = Criar(c);
        await host.StartAsync();
        var fila = host.Services.GetRequiredService<FilaPedidos>();
        _ = await fila.EnfileirarAguardandoAsync(new(Guid.Empty), CancellationToken.None);
        for (var i = 0; i < 10; i++)
            _ = await fila.EnfileirarAguardandoAsync(new(Guid.NewGuid()), CancellationToken.None);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        await host.StopAsync(timeout.Token);
        var resumo = Resumo(host, c);
        Assert.Equal(10, resumo.Processados);
        Assert.Equal(1, resumo.Falhas);
        Assert.Equal(0, resumo.ProfundidadeAtual);
        Assert.Equal(0, resumo.BancoEmExecucao);
        Assert.Equal(ResultadoEnfileiramento.Encerrado, fila.TentarEnfileirar(new(Guid.NewGuid())));
    }

    [Fact]
    public async Task Semaforo_Respeita_Teto_E_Nao_Perde_Slot()
    {
        var c = new ConfiguracaoFila(4, 8, 2, 25);
        using var host = Criar(c);
        await host.StartAsync();
        var fila = host.Services.GetRequiredService<FilaPedidos>();
        for (var i = 0; i < 20; i++)
            _ = await fila.EnfileirarAguardandoAsync(new(Guid.NewGuid()), CancellationToken.None);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(12));
        await host.StopAsync(timeout.Token);
        var resumo = Resumo(host, c);
        Assert.InRange(resumo.PicoBanco, 1, 2);
        Assert.Equal(0, resumo.BancoEmExecucao);
        Assert.Equal(20, resumo.Processados);
    }

    private static IHost Criar(ConfiguracaoFila c)
    {
        var builder = Host.CreateApplicationBuilder();
        builder.Logging.SetMinimumLevel(LogLevel.Warning);
        builder.Services.AdicionarPipelineR4(c);
        return builder.Build();
    }

    private static ResumoFila Resumo(IHost host, ConfiguracaoFila c) =>
        host.Services.GetRequiredService<MetricasFila>().Resumo(c,
            host.Services.GetRequiredService<Channel<ProcessarPedidoJob>>());
}
