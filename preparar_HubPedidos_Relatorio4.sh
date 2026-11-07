#!/usr/bin/env bash
set -euo pipefail
cd /workspaces/HubPedidos

printf '\n=== RELATORIO 4: PRE-CHECAGEM ===\n'
[[ "$(dotnet --version)" == 10.* ]] || { echo 'ERRO: SDK .NET 10 nao encontrado.'; exit 1; }
[[ "$(git branch --show-current)" == 'atividade-04-concorrencia' ]] || { echo 'ERRO: selecione a branch atividade-04-concorrencia.'; exit 1; }
[[ -f HubPedidos.sln && -f HubPedidos.Infrastructure/HubDbContext.cs && -f HubPedidos.Tests/HubPedidos.Tests.csproj ]] || { echo 'ERRO: solucao R1-R3 incompleta.'; exit 1; }
[[ ! -d HubPedidos.Relatorio4 && ! -f HubPedidos.Tests/Relatorio4PipelineTests.cs ]] || { echo 'ERRO: arquivos do R4 ja existem; script nao sobrescrevera.'; exit 1; }

mkdir -p evidencias/relatorio4
printf '\n=== Criando projeto web isolado para a demonstracao R4 ===\n'
dotnet new web -n HubPedidos.Relatorio4 -f net10.0
dotnet sln HubPedidos.sln add HubPedidos.Relatorio4/HubPedidos.Relatorio4.csproj
dotnet add HubPedidos.Relatorio4/HubPedidos.Relatorio4.csproj reference HubPedidos.Infrastructure/HubPedidos.Infrastructure.csproj
dotnet add HubPedidos.Tests/HubPedidos.Tests.csproj reference HubPedidos.Relatorio4/HubPedidos.Relatorio4.csproj
mkdir -p HubPedidos.Relatorio4/Pipeline

cat > HubPedidos.Relatorio4/Pipeline/ProcessarPedidoJob.cs <<'CS'
namespace HubPedidos.Relatorio4.Pipeline;

// Somente dados, sem DbContext ou entidade EF rastreada no canal.
public sealed record ProcessarPedidoJob(Guid PedidoId, DateTimeOffset? EnfileiradoEm = null);

public sealed record ConfiguracaoFila(int Capacidade, int Consumidores, int LimiteBanco, int AtrasoSimuladoMs = 50)
{
    public void Validar()
    {
        if (Capacidade <= 0 || Consumidores <= 0 || LimiteBanco <= 0 || AtrasoSimuladoMs < 0)
            throw new ArgumentOutOfRangeException(nameof(Capacidade), "Configuracao invalida.");
    }
}

public enum ResultadoEnfileiramento { Aceito, Duplicado, FilaCheia, Encerrado }
public enum EstadoPedido { EmFila, Processando, Concluido, Falhou }
CS

cat > HubPedidos.Relatorio4/Pipeline/MetricasFila.cs <<'CS'
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
CS

cat > HubPedidos.Relatorio4/Pipeline/FilaPedidos.cs <<'CS'
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
CS

cat > HubPedidos.Relatorio4/Pipeline/Persistencia.cs <<'CS'
using HubPedidos.Infrastructure;
using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Relatorio4.Pipeline;

public interface IPersistenciaPedido
{
    Task GravarAsync(ProcessarPedidoJob pedido, CancellationToken ct);
}

// Persistencia didatica, para carga repetivel sem alterar o banco R3.
public sealed class PersistenciaSimulada(ConfiguracaoFila config) : IPersistenciaPedido
{
    public async Task GravarAsync(ProcessarPedidoJob pedido, CancellationToken ct)
    {
        await Task.Delay(config.AtrasoSimuladoMs, ct);
        if (pedido.PedidoId == Guid.Empty)
            throw new InvalidOperationException("Falha controlada em pedido de teste.");
    }
}

// Persistencia REAL no PostgreSQL; usa DbContext scoped e PK como protecao de duplicidade.
public sealed class PersistenciaPostgres(HubDbContext db) : IPersistenciaPedido
{
    public async Task GravarAsync(ProcessarPedidoJob pedido, CancellationToken ct)
    {
        if (await db.Pedidos.AnyAsync(p => p.Id == pedido.PedidoId, ct)) return;
        db.Pedidos.Add(new PedidoRegistro
        {
            Id = pedido.PedidoId,
            Status = "FilaR4",
            CriadoEm = DateTime.UtcNow,
            Total = 1m,
            Endereco = new EnderecoEntrega { Cidade = "Exercicio", Uf = "SP" },
            Itens = new List<ItemPedidoRegistro>()
        });
        await db.SaveChangesAsync(ct);
    }
}
CS

cat > HubPedidos.Relatorio4/Pipeline/ConsumidorPedidos.cs <<'CS'
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
CS

cat > HubPedidos.Relatorio4/Pipeline/RegistroPipeline.cs <<'CS'
using System.Threading.Channels;
using HubPedidos.Infrastructure;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Npgsql;

namespace HubPedidos.Relatorio4.Pipeline;

public static class RegistroPipeline
{
    public static IServiceCollection AdicionarPipelineR4(
        this IServiceCollection services, ConfiguracaoFila config, bool postgres = false)
    {
        config.Validar();
        services.AddSingleton(config);
        services.AddSingleton(_ => Channel.CreateBounded<ProcessarPedidoJob>(
            new BoundedChannelOptions(config.Capacidade)
            {
                FullMode = BoundedChannelFullMode.Wait,
                SingleReader = false,
                SingleWriter = false
            }));
        services.AddSingleton<MetricasFila>();
        services.AddSingleton<FilaPedidos>();
        services.AddSingleton(new SemaphoreSlim(config.LimiteBanco, config.LimiteBanco));
        if (postgres)
        {
            var raw = Environment.GetEnvironmentVariable("HUBPEDIDOS_DB");
            if (string.IsNullOrWhiteSpace(raw))
                throw new InvalidOperationException("HUBPEDIDOS_DB ausente: configure sem expor credenciais.");
            // Pool local fixado em 20; limite de persistencia didatico menor que o pool.
            var conexao = new NpgsqlConnectionStringBuilder(raw) { MaxPoolSize = 20 }.ConnectionString;
            services.AddDbContext<HubDbContext>(o => o.UseNpgsql(conexao));
            services.AddScoped<IPersistenciaPedido, PersistenciaPostgres>();
        }
        else services.AddScoped<IPersistenciaPedido, PersistenciaSimulada>();
        services.AddHostedService<ConsumidorPedidos>();
        return services;
    }
}
CS

cat > HubPedidos.Relatorio4/Pipeline/Demonstracoes.cs <<'CS'
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
CS

cat > HubPedidos.Relatorio4/Program.cs <<'CS'
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
CS

cat > HubPedidos.Tests/Relatorio4PipelineTests.cs <<'CS'
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
CS

printf '\n=== Compilacao (sem necessitar do Neon nesta fase) ===\n'
dotnet restore HubPedidos.sln
dotnet build HubPedidos.sln -c Release --no-restore
printf '\n=== Testes R1-R4 sem dependencia de banco (7 testes novos) ===\n'
dotnet test HubPedidos.Tests/HubPedidos.Tests.csproj -c Release --no-build \
  --filter 'FullyQualifiedName~PedidosTests|FullyQualifiedName~ImportacaoLotesTests|FullyQualifiedName~Relatorio4PipelineTests' \
  --logger 'console;verbosity=minimal'
printf '\n=== Concluido. Leia as instrucoes antes de tirar as evidencias. ===\n'
