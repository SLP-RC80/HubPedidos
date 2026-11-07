#!/usr/bin/env bash
set -Eeuo pipefail

cd /workspaces/HubPedidos

echo '=== R6: PRE-CHECAGEM ==='
command -v dotnet >/dev/null || { echo 'ERRO: SDK dotnet ausente.' >&2; exit 1; }
[[ -f HubPedidos.sln && -f HubPedidos.Domain/HubPedidos.Domain.csproj && -f HubPedidos.Tests/HubPedidos.Tests.csproj ]] || {
  echo 'ERRO: execute na solucao HubPedidos existente (HubPedidos.sln, Domain e Tests obrigatorios).' >&2; exit 1;
}
echo "Branch atual: $(git branch --show-current 2>/dev/null || true)"
for p in HubPedidos.Modulos.Pedidos HubPedidos.Modulos.Processamento HubPedidos.Modulos.Notificacoes HubPedidos.Relatorio6 HubPedidos.Relatorio6.ClienteV1; do
  if [[ -e "$p" ]]; then
    echo "ERRO: $p ja existe. Para evitar sobrescrita, o script nao pode ser reexecutado integralmente." >&2
    echo 'Se houve erro de build, corrija os arquivos criados em vez de rodar o script outra vez.' >&2
    exit 1
  fi
done

echo '=== R6: CRIANDO PROJETOS ISOLADOS ==='
dotnet new classlib -n HubPedidos.Modulos.Pedidos -f net10.0 --no-restore
dotnet new classlib -n HubPedidos.Modulos.Processamento -f net10.0 --no-restore
dotnet new classlib -n HubPedidos.Modulos.Notificacoes -f net10.0 --no-restore
dotnet new web -n HubPedidos.Relatorio6 -f net10.0 --no-restore
dotnet new console -n HubPedidos.Relatorio6.ClienteV1 -f net10.0 --no-restore
rm -f HubPedidos.Modulos.{Pedidos,Processamento,Notificacoes}/Class1.cs

dotnet sln HubPedidos.sln add \
  HubPedidos.Modulos.Pedidos/HubPedidos.Modulos.Pedidos.csproj \
  HubPedidos.Modulos.Processamento/HubPedidos.Modulos.Processamento.csproj \
  HubPedidos.Modulos.Notificacoes/HubPedidos.Modulos.Notificacoes.csproj \
  HubPedidos.Relatorio6/HubPedidos.Relatorio6.csproj \
  HubPedidos.Relatorio6.ClienteV1/HubPedidos.Relatorio6.ClienteV1.csproj

dotnet add HubPedidos.Modulos.Pedidos/HubPedidos.Modulos.Pedidos.csproj reference HubPedidos.Domain/HubPedidos.Domain.csproj
dotnet add HubPedidos.Modulos.Processamento/HubPedidos.Modulos.Processamento.csproj reference HubPedidos.Modulos.Pedidos/HubPedidos.Modulos.Pedidos.csproj
dotnet add HubPedidos.Modulos.Notificacoes/HubPedidos.Modulos.Notificacoes.csproj reference HubPedidos.Modulos.Pedidos/HubPedidos.Modulos.Pedidos.csproj
dotnet add HubPedidos.Relatorio6/HubPedidos.Relatorio6.csproj reference \
  HubPedidos.Modulos.Pedidos/HubPedidos.Modulos.Pedidos.csproj \
  HubPedidos.Modulos.Processamento/HubPedidos.Modulos.Processamento.csproj \
  HubPedidos.Modulos.Notificacoes/HubPedidos.Modulos.Notificacoes.csproj
dotnet add HubPedidos.Relatorio6/HubPedidos.Relatorio6.csproj package Microsoft.AspNetCore.OpenApi --version 10.0.14

dotnet add HubPedidos.Tests/HubPedidos.Tests.csproj reference \
  HubPedidos.Relatorio6/HubPedidos.Relatorio6.csproj \
  HubPedidos.Relatorio6.ClienteV1/HubPedidos.Relatorio6.ClienteV1.csproj

cat > HubPedidos.Modulos.Pedidos/PedidosModulo.cs <<'CS'
using HubPedidos.Domain;

namespace HubPedidos.Modulos.Pedidos;

// Contratos do modulo: sem dependencia de ASP.NET Core, EF Core ou API.
public sealed record PedidoInfo(Guid Id, string Status, decimal Total);

public interface IRepositorioConsultaPedidos
{
    PedidoInfo? Obter(Guid id);
}

public static class PedidoExemplo
{
    public static readonly Guid Id = Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
}

// Adaptador em memoria: apenas para demonstracao arquitetural R6, sem alterar o Neon.
public sealed class RepositorioConsultaEmMemoria : IRepositorioConsultaPedidos
{
    private static readonly PedidoId IdTipado = PedidoId.Criar(PedidoExemplo.Id);

    public PedidoInfo? Obter(Guid id) => id == IdTipado.Valor
        ? new PedidoInfo(IdTipado.Valor, "Processando", 80.00m)
        : null;
}

// Servico scoped no modulo consumidor do contrato de repositorio.
public sealed class ConsultaPedidos(IRepositorioConsultaPedidos repositorio)
{
    public PedidoInfo? Obter(Guid id) => repositorio.Obter(id);
}
CS

cat > HubPedidos.Modulos.Processamento/ProcessamentoModulo.cs <<'CS'
using HubPedidos.Modulos.Pedidos;

namespace HubPedidos.Modulos.Processamento;

public interface IProcessadorPedido
{
    string CodigoSituacao(PedidoInfo pedido);
}

// Adaptador sem estado: pode ser registrado como transient.
public sealed class ProcessadorPedido : IProcessadorPedido
{
    public string CodigoSituacao(PedidoInfo pedido) => pedido.Status switch
    {
        "Processando" => "EM_PROCESSAMENTO",
        "Concluido" => "CONCLUIDO",
        _ => "DESCONHECIDO"
    };
}
CS

cat > HubPedidos.Modulos.Notificacoes/NotificacoesModulo.cs <<'CS'
using HubPedidos.Modulos.Pedidos;

namespace HubPedidos.Modulos.Notificacoes;

// Contrato de evento e apresentacao desacoplada do transporte de notificacoes.
public sealed record PedidoConsultado(Guid PedidoId, DateTimeOffset Em);

public interface INotificadorPedido
{
    string DescricaoSituacao(PedidoInfo pedido);
}

// Sem estado compartilhado mutavel: o registro singleton e seguro aqui.
public sealed class NotificadorPedido : INotificadorPedido
{
    public string DescricaoSituacao(PedidoInfo pedido) => pedido.Status switch
    {
        "Processando" => "Pedido em processamento",
        "Concluido" => "Pedido concluido",
        _ => "Situacao nao reconhecida"
    };
}
CS

cat > HubPedidos.Relatorio6/ModulosRegistracao.cs <<'CS'
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
CS

cat > HubPedidos.Relatorio6/ContratosApi.cs <<'CS'
using HubPedidos.Modulos.Pedidos;

namespace HubPedidos.Relatorio6;

// V1 mantem tipos e nomes de campos: id, status (string) e total (numero).
public sealed record PedidoV1Dto(Guid Id, string Status, decimal Total);

// V2 altera intencionalmente os tipos; a mudanca NAO afeta a rota V1.
public sealed record SituacaoV2Dto(string Codigo, string Descricao);
public sealed record TotalV2Dto(decimal Valor, string Moeda);
public sealed record PedidoV2Dto(Guid Id, SituacaoV2Dto Situacao, TotalV2Dto Total);

public static class ContratosApi
{
    public static PedidoV1Dto ParaV1(PedidoInfo pedido) =>
        new(pedido.Id, pedido.Status, pedido.Total);

    public static PedidoV2Dto ParaV2(PedidoInfo pedido, string codigo, string descricao) =>
        new(pedido.Id, new SituacaoV2Dto(codigo, descricao), new TotalV2Dto(pedido.Total, "BRL"));
}

// Telemetria didatica de uso do contrato antigo, sem impor data arbitraria de remocao.
public sealed class ContadorUsoV1
{
    private long _leituras;
    public long Leituras => Interlocked.Read(ref _leituras);
    public void Registrar() => Interlocked.Increment(ref _leituras);
}
CS

cat > HubPedidos.Relatorio6/ApiEndpoints.cs <<'CS'
using HubPedidos.Modulos.Pedidos;
using HubPedidos.Modulos.Processamento;
using HubPedidos.Modulos.Notificacoes;
using Microsoft.AspNetCore.Http;

namespace HubPedidos.Relatorio6;

public static class ApiEndpoints
{
    public static IResult ObterV1(Guid id, ConsultaPedidos pedidos, ContadorUsoV1 uso)
    {
        var pedido = pedidos.Obter(id);
        if (pedido is null) return Results.NotFound(new { erro = "Pedido nao encontrado." });
        uso.Registrar();
        return Results.Ok(ContratosApi.ParaV1(pedido));
    }

    public static IResult ObterV2(Guid id, ConsultaPedidos pedidos,
        IProcessadorPedido processamento, INotificadorPedido notificacoes)
    {
        var pedido = pedidos.Obter(id);
        if (pedido is null) return Results.NotFound(new { erro = "Pedido nao encontrado." });
        return Results.Ok(ContratosApi.ParaV2(
            pedido, processamento.CodigoSituacao(pedido), notificacoes.DescricaoSituacao(pedido)));
    }
}
CS

cat > HubPedidos.Relatorio6/Program.cs <<'CS'
using HubPedidos.Relatorio6;

var builder = WebApplication.CreateBuilder(args);

builder.Host.UseDefaultServiceProvider((_, options) =>
{
    options.ValidateScopes = true;
    options.ValidateOnBuild = true;
});

builder.Services.AddOpenApi();
builder.Services.AddPedidosModule()
                .AddProcessamentoModule()
                .AddNotificacoesModule();
builder.Services.AddSingleton<ContadorUsoV1>();

var app = builder.Build();
app.MapOpenApi();
app.MapGet("/health", () => Results.Ok(new { status = "ok", modulo = "R6" }));

app.MapGet("/api/v1/pedidos/{id:guid}", ApiEndpoints.ObterV1)
    .WithName("ObterPedidoV1")
    .WithSummary("Obter pedido no contrato legado V1 (estavel)")
    .WithDescription("Compatibilidade mantida: id UUID, status string, total numero.")
    .Produces<PedidoV1Dto>(StatusCodes.Status200OK)
    .Produces(StatusCodes.Status404NotFound);

app.MapGet("/api/v2/pedidos/{id:guid}", ApiEndpoints.ObterV2)
    .WithName("ObterPedidoV2")
    .WithSummary("Obter pedido no contrato V2")
    .WithDescription("Mudanca intencional de contrato: situacao e total sao objetos.")
    .Produces<PedidoV2Dto>(StatusCodes.Status200OK)
    .Produces(StatusCodes.Status404NotFound);

app.MapGet("/api/metricas/versoes", (ContadorUsoV1 uso) =>
    Results.Ok(new { leiturasV1 = uso.Leituras }))
    .WithSummary("Telemetria de uso do contrato V1");

// Politica explicita de selecao: /api/pedidos/{id} e /api/v3/... nao sao mapeadas => 404.
app.Run();
CS

cat > HubPedidos.Relatorio6.ClienteV1/Program.cs <<'CS'
using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

// Cliente compilado com o contrato antigo. Nao referencia o projeto da nova API.
var origem = args.Length > 0 ? args[0] : "http://localhost:5086";
using var http = new HttpClient { BaseAddress = new Uri(origem), Timeout = TimeSpan.FromSeconds(10) };
const string id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";

var respostaV1 = await http.GetAsync($"/api/v1/pedidos/{id}");
respostaV1.EnsureSuccessStatusCode();
var v1 = await respostaV1.Content.ReadFromJsonAsync<PedidoLegadoV1>();
if (v1 is null || v1.Id == Guid.Empty || string.IsNullOrWhiteSpace(v1.Status) || v1.Total <= 0)
    throw new Exception("Contrato V1 incompativel com o cliente legado.");
Console.WriteLine($"R6.04 CLIENTE V1: HTTP={(int)respostaV1.StatusCode}; status={v1.Status}; total={v1.Total}; COMPATIVEL=SIM");

var respostaV2 = await http.GetAsync($"/api/v2/pedidos/{id}");
respostaV2.EnsureSuccessStatusCode();
using (var jsonV2 = JsonDocument.Parse(await respostaV2.Content.ReadAsStringAsync()))
{
    var situacaoObjeto = jsonV2.RootElement.GetProperty("situacao").ValueKind == JsonValueKind.Object;
    var totalObjeto = jsonV2.RootElement.GetProperty("total").ValueKind == JsonValueKind.Object;
    if (!situacaoObjeto || !totalObjeto) throw new Exception("V2 deveria introduzir a mudanca contratual.");
    Console.WriteLine($"R6.04 V2: HTTP={(int)respostaV2.StatusCode}; situacao_objeto={situacaoObjeto}; total_objeto={totalObjeto}");
}

var semVersao = await http.GetAsync($"/api/pedidos/{id}");
var desconhecida = await http.GetAsync($"/api/v3/pedidos/{id}");
if (semVersao.StatusCode != HttpStatusCode.NotFound || desconhecida.StatusCode != HttpStatusCode.NotFound)
    throw new Exception("Politica de versao ausente/desconhecida diferente de HTTP 404.");
Console.WriteLine($"R6.04 POLITICA: sem_versao={(int)semVersao.StatusCode}; desconhecida_v3={(int)desconhecida.StatusCode} (esperado 404/404)");
Console.WriteLine("R6.04 RESULTADO: cliente legado funcional sem modificacao; v1 e v2 coexistem.");

public sealed record PedidoLegadoV1(Guid Id, string Status, decimal Total);
CS

cat > HubPedidos.Tests/Relatorio6ArquiteturaTests.cs <<'CS'
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
CS

cat > HubPedidos.Relatorio6/arquitetura.md <<'MD'
# R6.01 – Grafo de modulos (referencias reais de projeto)

```mermaid
flowchart TD
    API["HubPedidos.Relatorio6 (API / composition root)"] --> PED["HubPedidos.Modulos.Pedidos"]
    API --> PROC["HubPedidos.Modulos.Processamento"]
    API --> NOTI["HubPedidos.Modulos.Notificacoes"]
    PROC --> PED
    NOTI --> PED
    PED --> DOM["HubPedidos.Domain (regras independentes)"]
    CLIENT["HubPedidos.Relatorio6.ClienteV1"] -. "HTTP v1 (sem referencia de projeto)" .-> API
```

Verificacao: `dotnet list <projeto.csproj> reference` e testes de referencia entre assemblies.
O projeto **Domain** nao deve referenciar a API, a infraestrutura nem EF Core.
A infraestrutura dos relatorios anteriores continua preservada; este exemplo usa repositorio em memoria somente em R6.
MD

cat > HubPedidos.Relatorio6/politica_versoes.md <<'MD'
# R6.03/R6.04 – Politica de versionamento e transicao

- Selecao explicita por URL: `GET /api/v1/pedidos/{id}` e `GET /api/v2/pedidos/{id}`.
- V1 mantida: `{ "id": "...", "status": "Processando", "total": 80.00 }`.
- V2 incompatível, somente na nova rota: `{ "id": "...", "situacao": { "codigo": "EM_PROCESSAMENTO", "descricao": "Pedido em processamento" }, "total": { "valor": 80.00, "moeda": "BRL" } }`.
- Sem versao (`/api/pedidos/{id}`) e versao nao suportada (`/api/v3/...`) retornam HTTP **404**; nao ha substituicao silenciosa.
- O endpoint `/api/metricas/versoes` demonstra contagem de acesso bem-sucedido a v1.
- Uma futura descontinuacao exige monitorar clientes v1, comunicar migracao e definir cronograma. Esta atividade **nao** remove v1 e nao estabelece prazo de desativacao.
- Documento OpenAPI disponivel em `/openapi/v1.json` (nome do documento OpenAPI, **nao** somente a versao de rotas); ambas as rotas devem aparecer na secao `paths`.
MD

cat > HubPedidos.Relatorio6/testar_http.sh <<'BASH2'
#!/usr/bin/env bash
set -euo pipefail
BASE="${1:-http://localhost:5086}"
ID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
printf '\n=== R6.03 V1 ===\n'
curl -sS -i "$BASE/api/v1/pedidos/$ID"
printf '\n\n=== R6.03 V2 ===\n'
curl -sS -i "$BASE/api/v2/pedidos/$ID"
printf '\n\n=== R6.03 SEM VERSAO ===\n'
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "$BASE/api/pedidos/$ID"
printf '\n=== R6.03 VERSAO DESCONHECIDA ===\n'
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "$BASE/api/v3/pedidos/$ID"
printf '\n=== R6.03 OPENAPI - ROTAS ===\n'
curl -fsS "$BASE/openapi/v1.json" | python3 -c 'import json,sys; doc=json.load(sys.stdin); print("OpenAPI",doc.get("openapi")); print("\n".join(sorted(doc.get("paths",{}))))'
printf '\n=== R6.04 TELEMETRIA V1 ===\n'
curl -sS "$BASE/api/metricas/versoes"; printf '\n'
BASH2
chmod +x HubPedidos.Relatorio6/testar_http.sh

cat > HubPedidos.Relatorio6/roteiro_evidencias.md <<'MD'
# Controle das capturas – Relatorio 6

| ID | Momento exato | Evidencia |
|---|---|---|
| R6.01-A | Abrir `arquitetura.md` em Preview, exibindo o diagrama | Fronteiras dos 3 modulos, Domain e API |
| R6.01-B | `dotnet list HubPedidos.Modulos.Pedidos/HubPedidos.Modulos.Pedidos.csproj reference` + testes de fronteira | Referencias e isolamento do dominio |
| R6.02-A | Abrir `ModulosRegistracao.cs` e `Program.cs` | Tres extensoes `Add*Module`, lifetimes e chamada no composition root |
| R6.02-B | Filtrar `Relatorio6ArquiteturaTests` | Testes de DI valido e singleton capturando scoped rejeitado |
| R6.03-A | `curl http://localhost:5086/openapi/v1.json` com lista das rotas | Documentacao de v1/v2, ambas presentes |
| R6.03-B | `bash HubPedidos.Relatorio6/testar_http.sh` | Retorno HTTP 200 v1, 200 v2 e contratos distintos |
| R6.04-A | `dotnet run --project HubPedidos.Relatorio6.ClienteV1 -c Release` | Cliente v1 funciona sem alteracao; politica 404/404 |
| R6.04-B | `dotnet test ... --filter FullyQualifiedName~Relatorio6ArquiteturaTests` | Oito testes especificos aprovados |
| R6.04-C | `dotnet test -c Release` (Neon ativo para testes R3) | Suíte geral aprovada |

Capturas de codigo podem mostrar so trecho. Na consolidacao Word, listar os caminhos integrais na secao 3.6.
MD

mkdir -p HubPedidos.Relatorio6/evidencias
cat > HubPedidos.Relatorio6/.gitignore <<'GIT'
evidencias/*.log
GIT

echo '=== R6: REFERENCIAS REAIS (R6.01) ==='
for p in HubPedidos.Domain HubPedidos.Modulos.Pedidos HubPedidos.Modulos.Processamento HubPedidos.Modulos.Notificacoes HubPedidos.Relatorio6 HubPedidos.Relatorio6.ClienteV1; do
  echo "--- $p ---"
  dotnet list "$p/$p.csproj" reference || true
done

echo '=== R6: BUILD RELEASE (a compilar no Codespaces) ==='
dotnet build HubPedidos.sln -c Release

echo '=== R6: TESTES ESPECIFICOS (sem depender do Neon) ==='
dotnet test HubPedidos.Tests/HubPedidos.Tests.csproj \
  -c Release --no-build \
  --filter 'FullyQualifiedName~Relatorio6ArquiteturaTests' \
  --logger 'console;verbosity=normal'

echo '=== R6: PREPARACAO CONCLUIDA ==='
echo 'R6.01: arquitetura.md e referencia entre projetos'
echo 'R6.02: ModulosRegistracao.cs + oito testes especificos'
echo 'R6.03: iniciar API na porta 5086 e testar_http.sh'
echo 'R6.04: executar cliente legado separado e regressao geral com Neon'
