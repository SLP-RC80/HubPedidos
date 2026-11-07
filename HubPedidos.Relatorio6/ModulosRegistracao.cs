using HubPedidos.Modulos.Pedidos;
using HubPedidos.Modulos.Processamento;
using HubPedidos.Modulos.Notificacoes;
using Microsoft.Extensions.DependencyInjection;

namespace HubPedidos.Relatorio6;

// Composition root: a API conhece as implementacoes; o dominio nao conhece a API.
public static class ModulosRegistracao
{
    public static IServiceCollection AddPedidosModule(this IServiceCollection services)
    {
        services.AddScoped<IRepositorioConsultaPedidos, RepositorioConsultaEmMemoria>();
        services.AddScoped<ConsultaPedidos>();
        return services;
    }

    public static IServiceCollection AddProcessamentoModule(this IServiceCollection services)
    {
        services.AddTransient<IProcessadorPedido, ProcessadorPedido>();
        return services;
    }

    public static IServiceCollection AddNotificacoesModule(this IServiceCollection services)
    {
        services.AddSingleton<INotificadorPedido, NotificadorPedido>();
        return services;
    }
}
