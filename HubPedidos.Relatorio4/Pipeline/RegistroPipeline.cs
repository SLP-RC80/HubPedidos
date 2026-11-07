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
