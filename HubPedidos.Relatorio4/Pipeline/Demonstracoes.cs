using System.Diagnostics;
using System.Threading.Channels;
using HubPedidos.Infrastructure;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace HubPedidos.Relatorio4.Pipeline;

public static class Demonstracoes
{
    private static IHost CriarHost(ConfiguracaoFila config, bool postgres = false)
    {
        var builder = Host.CreateApplicationBuilder();
        builder.Logging.SetMinimumLevel(LogLevel.Warning);
        builder.Services.AdicionarPipelineR4(config, postgres);
        return builder.Build();
    }

    private static void Imprimir(string titulo, ResumoFila r, TimeSpan duracao)
    {
        var vazao = duracao.TotalSeconds > 0 ? r.Processados / duracao.TotalSeconds : 0;
        Console.WriteLine($"R4.04 {titulo}: capacidade={r.Capacidade} consumidores={r.Consumidores} limite_banco={r.LimiteBanco}");
        Console.WriteLine($"R4.04 {titulo}: aceitos={r.Aceitos} processados={r.Processados} falhas={r.Falhas} rejeitados={r.Rejeitados} descartados={r.Descartados} duplicados={r.Duplicados}");
        Console.WriteLine($"R4.04 {titulo}: pico_fila={r.PicoFila} pico_banco={r.PicoBanco} espera_media_ms={r.EsperaMediaMs:F2} latencia_media_ms={r.LatenciaMediaMs:F2} vazao_pedidos_s={vazao:F2}");
        if (r.Aceitos != r.Processados + r.Falhas || r.PicoBanco > r.LimiteBanco)
            throw new InvalidOperationException("Invariantes da pipeline violadas.");
    }

    private static async Task CenárioAsync(string nome, ConfiguracaoFila c)
    {
        using var host = CriarHost(c);
        await host.StartAsync();
        var fila = host.Services.GetRequiredService<FilaPedidos>();
        var metricas = host.Services.GetRequiredService<MetricasFila>();
        var tempo = Stopwatch.StartNew();
        for (var i = 0; i < 120; i++)
        {
            _ = fila.TentarEnfileirar(new ProcessarPedidoJob(Guid.NewGuid()));
            await Task.Delay(1);
        }
        using var prazo = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        await host.StopAsync(prazo.Token);
        tempo.Stop();
        var resumo = metricas.Resumo(c, host.Services.GetRequiredService<Channel<ProcessarPedidoJob>>());
        Imprimir(nome, resumo, tempo.Elapsed);
    }

    public static async Task CenáriosAsync()
    {
        Console.WriteLine("R4.04 EXPERIMENTO: mesma carga de 120 tentativas, produtor com intervalo de 1ms; persistencia simulada (35ms/item) para controlar o ambiente.");
        await CenárioAsync("CENARIO_A", new ConfiguracaoFila(8, 1, 1, 35));
        await CenárioAsync("CENARIO_B", new ConfiguracaoFila(40, 4, 2, 35));
        Console.WriteLine("R4.04 ANALISE: rejeitados diferem de descartados; maior paralelismo nao e melhoria automatica no banco real.");
    }

    public static async Task EsperaAsync()
    {
        var c = Channel.CreateBounded<int>(new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.Wait });
        await c.Writer.WriteAsync(1);
        var segundo = c.Writer.WriteAsync(2).AsTask();
        await Task.Delay(60);
        Console.WriteLine($"R4.01 WAIT: segundo_produtor_aguardando={!segundo.IsCompleted} (esperado: True)");
        _ = await c.Reader.ReadAsync();
        await segundo.WaitAsync(TimeSpan.FromSeconds(2));
        Console.WriteLine("R4.01 WAIT: segundo_produtor_liberado=True");
        c.Writer.TryComplete();
    }

    public static async Task FalhaEShutdownAsync()
    {
        var c = new ConfiguracaoFila(4, 3, 2, 25);
        using var host = CriarHost(c);
        await host.StartAsync();
        var fila = host.Services.GetRequiredService<FilaPedidos>();
        _ = await fila.EnfileirarAguardandoAsync(new ProcessarPedidoJob(Guid.Empty), CancellationToken.None);
        for (var i = 0; i < 12; i++)
            _ = await fila.EnfileirarAguardandoAsync(new ProcessarPedidoJob(Guid.NewGuid()), CancellationToken.None);
        using var prazo = new CancellationTokenSource(TimeSpan.FromSeconds(15));
        await host.StopAsync(prazo.Token);
        var metricas = host.Services.GetRequiredService<MetricasFila>();
        var res = metricas.Resumo(c, host.Services.GetRequiredService<Channel<ProcessarPedidoJob>>());
        Console.WriteLine($"R4.02 SHUTDOWN: aceitos={res.Aceitos} processados={res.Processados} falhas_isoladas={res.Falhas} pendentes={res.ProfundidadeAtual}");
        Console.WriteLine($"R4.02 SHUTDOWN: nova_entrada={fila.TentarEnfileirar(new ProcessarPedidoJob(Guid.NewGuid()))} (esperado: Encerrado)");
        Console.WriteLine($"R4.03 LIMITE: pico_banco={res.PicoBanco} limite_banco={res.LimiteBanco}");
        if (res.Aceitos != res.Processados + res.Falhas || res.Falhas != 1 || res.PicoBanco > res.LimiteBanco)
            throw new InvalidOperationException("Teste de falha/shutdown falhou.");
    }

    public static async Task BancoAsync()
    {
        var c = new ConfiguracaoFila(12, 4, 2, 0);
        using var host = CriarHost(c, postgres: true);
        await host.StartAsync();
        int antes;
        using (var scope = host.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HubDbContext>();
            antes = await db.Pedidos.CountAsync(p => p.Status == "FilaR4");
        }
        var fila = host.Services.GetRequiredService<FilaPedidos>();
        var idsTemporarios = Enumerable.Range(0, 8).Select(_ => Guid.NewGuid()).ToList();
        foreach (var id in idsTemporarios)
            _ = await fila.EnfileirarAguardandoAsync(new ProcessarPedidoJob(id), CancellationToken.None);
        using var prazo = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        await host.StopAsync(prazo.Token);
        int depois;
        using (var scope = host.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HubDbContext>();
            depois = await db.Pedidos.CountAsync(p => p.Status == "FilaR4");
        }
        var res = host.Services.GetRequiredService<MetricasFila>()
            .Resumo(c, host.Services.GetRequiredService<Channel<ProcessarPedidoJob>>());
        Console.WriteLine($"R4.03 POSTGRES: novos_pedidos={depois - antes}; pico_banco={res.PicoBanco}; limite_banco={c.LimiteBanco}; falhas={res.Falhas}; pool_maximo=20");
        if (res.Processados != 8 || res.Falhas != 0 || res.PicoBanco > c.LimiteBanco || depois - antes != 8)
            throw new InvalidOperationException("Persistencia PostgreSQL nao validada.");
        // Limpeza: preserva as contagens e o ambiente do Relatorio 3.
        using (var scope = host.Services.CreateScope())
        {
            var db = scope.ServiceProvider.GetRequiredService<HubDbContext>();
            var removidos = await db.Pedidos.Where(p => idsTemporarios.Contains(p.Id)).ExecuteDeleteAsync();
            Console.WriteLine($"R4.03 POSTGRES: registros_temporarios_removidos={removidos}");
        }
    }
}
