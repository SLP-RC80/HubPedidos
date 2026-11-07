extern alias R6;
extern alias R7;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using Xunit;
using PedidoPersistido = R7::HubPedidos.Relatorio7.PedidoPersistido;
using ExemplosR7 = R7::HubPedidos.Relatorio7.ExemplosR7;

namespace HubPedidos.IntegrationTests;

public sealed class Relatorio8HttpTests
{
    private static HttpClient Autenticado(FabricaR7 host, string usuario)
    {
        var cliente = host.CriarCliente();
        cliente.DefaultRequestHeaders.Authorization =
            new AuthenticationHeaderValue("Bearer", usuario == "alice" ? host.ChaveAlice : host.ChaveBob);
        return cliente;
    }

    [Fact]
    public async Task R8_01_Testing_Usa_Sqlite_Efemero_Em_Memoria()
    {
        using var host = new FabricaR7();
        using var cliente = Autenticado(host, "alice");
        var resposta = await cliente.GetAsync($"/api/v1/pedidos/{ExemplosR7.AliceId:D}");
        Assert.Equal(HttpStatusCode.OK, resposta.StatusCode);
        Assert.Equal(System.Data.ConnectionState.Open, host.Conexao.Estado);
        Assert.Equal(":memory:", host.Conexao.DataSource);
        using var scope = host.CriarEscopo();
        var db = scope.ServiceProvider.GetRequiredService<R7::HubPedidos.Relatorio7.R7DbContext>();
        Assert.Equal("Microsoft.EntityFrameworkCore.Sqlite", db.Database.ProviderName);
    }

    [Fact]
    public async Task R8_02_Criacao_De_Dado_Em_Seed_Controlado_E_Consulta_Pelo_Http()
    {
        using var host = new FabricaR7();
        using var cliente = Autenticado(host, "alice");
        // O R7 nao possui POST /pedidos: o dado e criado na fixture, consultado via HttpClient.
        var novoId = Guid.NewGuid();
        using (var scope = host.CriarEscopo())
        {
            var db = scope.ServiceProvider.GetRequiredService<R7::HubPedidos.Relatorio7.R7DbContext>();
            db.Pedidos.Add(new PedidoPersistido
            {
                Id = novoId,
                Proprietario = "alice",
                Regiao = "SP",
                Status = "Processando",
                Total = 42.5m,
                Versao = 1,
                AtualizadoEm = DateTimeOffset.UtcNow
            });
            await db.SaveChangesAsync();
        }
        using var resposta = await cliente.GetAsync($"/api/v1/pedidos/{novoId:D}");
        Assert.Equal(HttpStatusCode.OK, resposta.StatusCode);
        using var json = JsonDocument.Parse(await resposta.Content.ReadAsStringAsync());
        Assert.Equal(novoId.ToString("D"), json.RootElement.GetProperty("id").GetString());
    }

    [Fact]
    public async Task R8_02_V1_E_V2_Conservam_Contratos_Distintos()
    {
        using var fabrica = new WebApplicationFactory<R6::Program>();
        using var cliente = fabrica.CreateClient();
        const string id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
        using var v1 = await cliente.GetAsync("/api/v1/pedidos/" + id);
        using var v2 = await cliente.GetAsync("/api/v2/pedidos/" + id);
        Assert.Equal(HttpStatusCode.OK, v1.StatusCode);
        Assert.Equal(HttpStatusCode.OK, v2.StatusCode);
        using var documento1 = JsonDocument.Parse(await v1.Content.ReadAsStringAsync());
        using var documento2 = JsonDocument.Parse(await v2.Content.ReadAsStringAsync());
        Assert.Equal(JsonValueKind.String, documento1.RootElement.GetProperty("status").ValueKind);
        Assert.Equal(JsonValueKind.Number, documento1.RootElement.GetProperty("total").ValueKind);
        Assert.Equal(JsonValueKind.Object, documento2.RootElement.GetProperty("situacao").ValueKind);
        Assert.Equal(JsonValueKind.Object, documento2.RootElement.GetProperty("total").ValueKind);
        Assert.Equal(HttpStatusCode.NotFound, (await cliente.GetAsync("/api/v3/pedidos/" + id)).StatusCode);
    }

    [Fact]
    public async Task R8_02_Etag_304_Sem_Corpo_E_Alteracao_Condicional()
    {
        using var host = new FabricaR7();
        using var cliente = Autenticado(host, "alice");
        var rota = $"/api/v1/pedidos/{ExemplosR7.AliceId:D}";
        using var primeira = await cliente.GetAsync(rota);
        Assert.Equal(HttpStatusCode.OK, primeira.StatusCode);
        var etag = primeira.Headers.ETag?.ToString();
        Assert.False(string.IsNullOrWhiteSpace(etag));
        using var condicional = new HttpRequestMessage(HttpMethod.Get, rota);
        condicional.Headers.TryAddWithoutValidation("If-None-Match", etag);
        using var semMudanca = await cliente.SendAsync(condicional);
        Assert.Equal(HttpStatusCode.NotModified, semMudanca.StatusCode);
        Assert.Empty(await semMudanca.Content.ReadAsByteArrayAsync());
        using var atualizar = new HttpRequestMessage(HttpMethod.Put, rota + "/status");
        atualizar.Headers.TryAddWithoutValidation("If-Match", etag);
        atualizar.Content = JsonContent.Create(new { status = "Concluido" });
        using var atualizada = await cliente.SendAsync(atualizar);
        Assert.Equal(HttpStatusCode.OK, atualizada.StatusCode);
        using var nova = await cliente.GetAsync(rota);
        Assert.NotEqual(etag, nova.Headers.ETag?.ToString());
    }

    [Fact]
    public async Task R8_02_Autorizacao_Nega_Acesso_Indevido()
    {
        using var host = new FabricaR7();
        using var anonimo = host.CriarCliente();
        using var bob = Autenticado(host, "bob");
        var rota = $"/api/v1/pedidos/{ExemplosR7.AliceId:D}";
        Assert.Equal(HttpStatusCode.Unauthorized, (await anonimo.GetAsync(rota)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await bob.GetAsync(rota)).StatusCode);
    }

    [Fact]
    public async Task R8_02_Catalogo_Publico_Varia_Por_Regiao()
    {
        using var host = new FabricaR7();
        using var cliente = host.CriarCliente();
        const string baseRota = "/api/publico/catalogo-status?regiao=";
        var sp1 = await cliente.GetStringAsync(baseRota + "SP");
        var sp2 = await cliente.GetStringAsync(baseRota + "SP");
        var rj = await cliente.GetStringAsync(baseRota + "RJ");
        Assert.Equal(sp1, sp2);
        Assert.NotEqual(sp1, rj);
    }

    [Fact]
    public async Task R8_01_Isolamento_De_Fabricas_Impede_Contaminacao_Entre_Testes()
    {
        var id = Guid.NewGuid();
        using (var hostA = new FabricaR7())
        {
            using var cliente = Autenticado(hostA, "alice");
            using (var scope = hostA.CriarEscopo())
            {
                var db = scope.ServiceProvider.GetRequiredService<R7::HubPedidos.Relatorio7.R7DbContext>();
                db.Pedidos.Add(new PedidoPersistido
                {
                    Id = id,
                    Proprietario = "alice",
                    Regiao = "SP",
                    Status = "Concluido",
                    Total = 10m,
                    Versao = 1,
                    AtualizadoEm = DateTimeOffset.UtcNow
                });
                await db.SaveChangesAsync();
            }
            Assert.Equal(HttpStatusCode.OK, (await cliente.GetAsync($"/api/v1/pedidos/{id:D}")).StatusCode);
        }
        using (var hostB = new FabricaR7())
        {
            using var cliente = Autenticado(hostB, "alice");
            Assert.Equal(HttpStatusCode.NotFound, (await cliente.GetAsync($"/api/v1/pedidos/{id:D}")).StatusCode);
        }
    }
}
