using System.Reflection;
using System.Text.Json;
using HubPedidos.Domain;
using HubPedidos.Modulos.Pedidos;
using HubPedidos.Modulos.Processamento;
using HubPedidos.Modulos.Notificacoes;
using HubPedidos.Relatorio6;
using Microsoft.Extensions.DependencyInjection;
using Xunit;

namespace HubPedidos.Tests;

public sealed class Relatorio6ArquiteturaTests
{
    private static readonly JsonSerializerOptions WebJson = new(JsonSerializerDefaults.Web);

    [Fact]
    public void Dominio_Nao_Referencia_Web_Infra_Ou_EFCore()
    {
        var nomes = typeof(PedidoId).Assembly.GetReferencedAssemblies().Select(a => a.Name ?? "");
        Assert.DoesNotContain(nomes, n => n.StartsWith("Microsoft.AspNetCore") ||
                                       n.StartsWith("Microsoft.EntityFrameworkCore") ||
                                       n.Contains("HubPedidos.Infrastructure") ||
                                       n.Contains("HubPedidos.Api"));
    }

    [Fact]
    public void Modulo_Pedidos_Nao_Referencia_Host_Ou_Persistencia()
    {
        var nomes = typeof(PedidoInfo).Assembly.GetReferencedAssemblies().Select(a => a.Name ?? "");
        Assert.DoesNotContain(nomes, n => n.Contains("HubPedidos.Relatorio6") ||
                                       n.Contains("HubPedidos.Infrastructure") ||
                                       n.StartsWith("Microsoft.AspNetCore") ||
                                       n.StartsWith("Microsoft.EntityFrameworkCore"));
    }

    [Fact]
    public void Grafo_DI_Valido_Com_Lifetimes_Adequados()
    {
        var services = new ServiceCollection();
        services.AddPedidosModule().AddProcessamentoModule().AddNotificacoesModule();
        using var raiz = services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true, ValidateScopes = true
        });
        using var escopo = raiz.CreateScope();
        Assert.NotNull(escopo.ServiceProvider.GetRequiredService<ConsultaPedidos>()
            .Obter(PedidoExemplo.Id));
        Assert.NotNull(escopo.ServiceProvider.GetRequiredService<IProcessadorPedido>());
        Assert.NotNull(escopo.ServiceProvider.GetRequiredService<INotificadorPedido>());
    }

    public sealed class SingletonErrado(IRepositorioConsultaPedidos dependenciaScoped)
    {
        public IRepositorioConsultaPedidos Dependencia => dependenciaScoped;
    }

    [Fact]
    public void Grafo_DI_Rejeita_Singleton_Capturando_Scoped()
    {
        var services = new ServiceCollection();
        services.AddScoped<IRepositorioConsultaPedidos, RepositorioConsultaEmMemoria>();
        services.AddSingleton<SingletonErrado>();
        var erro = Record.Exception(() => services.BuildServiceProvider(new ServiceProviderOptions
        {
            ValidateOnBuild = true, ValidateScopes = true
        }));
        Assert.NotNull(erro);
        Assert.Contains("scoped", erro!.ToString().ToLowerInvariant());
    }

    [Fact]
    public void V1_Continua_Com_Status_String_E_Total_Numero()
    {
        var json = JsonSerializer.Serialize(ContratosApi.ParaV1(
            new PedidoInfo(PedidoExemplo.Id, "Processando", 80m)), WebJson);
        using var documento = JsonDocument.Parse(json);
        Assert.Equal(JsonValueKind.String, documento.RootElement.GetProperty("status").ValueKind);
        Assert.Equal(JsonValueKind.Number, documento.RootElement.GetProperty("total").ValueKind);
        Assert.Equal("Processando", documento.RootElement.GetProperty("status").GetString());
    }

    [Fact]
    public void V2_Introduz_Objetos_No_Status_E_Total()
    {
        var json = JsonSerializer.Serialize(ContratosApi.ParaV2(
            new PedidoInfo(PedidoExemplo.Id, "Processando", 80m), "EM_PROCESSAMENTO", "Pedido em processamento"), WebJson);
        using var documento = JsonDocument.Parse(json);
        Assert.Equal(JsonValueKind.Object, documento.RootElement.GetProperty("situacao").ValueKind);
        Assert.Equal(JsonValueKind.Object, documento.RootElement.GetProperty("total").ValueKind);
    }

    private sealed record ContratoAntigo(Guid Id, string Status, decimal Total);

    [Fact]
    public void Cliente_V1_Continua_Desserializando_Resposta_Legada()
    {
        var json = JsonSerializer.Serialize(ContratosApi.ParaV1(
            new PedidoInfo(PedidoExemplo.Id, "Processando", 80m)), WebJson);
        var pedido = JsonSerializer.Deserialize<ContratoAntigo>(json, WebJson);
        Assert.NotNull(pedido);
        Assert.Equal("Processando", pedido!.Status);
        Assert.Equal(80m, pedido.Total);
    }

    [Fact]
    public void Mudanca_V2_Nao_Eh_Interpretada_Como_V1()
    {
        var json = JsonSerializer.Serialize(ContratosApi.ParaV2(
            new PedidoInfo(PedidoExemplo.Id, "Processando", 80m), "EM_PROCESSAMENTO", "Pedido em processamento"), WebJson);
        Assert.Throws<JsonException>(() => JsonSerializer.Deserialize<ContratoAntigo>(json, WebJson));
    }
}
