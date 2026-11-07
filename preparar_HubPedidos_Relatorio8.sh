#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos

printf '\n=== R8 PRE-CHECAGEM ===\n'
command -v dotnet >/dev/null || { echo 'ERRO: dotnet nao encontrado.' >&2; exit 1; }
[[ -f HubPedidos.sln && -f HubPedidos.Tests/HubPedidos.Tests.csproj && -f HubPedidos.Relatorio4/HubPedidos.Relatorio4.csproj && -f HubPedidos.Relatorio6/HubPedidos.Relatorio6.csproj && -f HubPedidos.Relatorio7/HubPedidos.Relatorio7.csproj ]] || {
  echo 'ERRO: necessita da solucao completa com R4, R6 e R7.' >&2; exit 1;
}
branch=$(git branch --show-current)
echo "Branch: $branch"
[[ "$branch" == "atividade-08-qualidade" ]] || { echo 'ERRO: crie/acesse a branch atividade-08-qualidade antes de executar.' >&2; exit 1; }
[[ ! -e HubPedidos.IntegrationTests ]] || { echo 'ERRO: HubPedidos.IntegrationTests ja existe; o script nao sobrescreve projetos. Corrija arquivos individualmente.' >&2; exit 1; }
[[ ! -e .github/workflows/r8-qualidade.yml ]] || { echo 'ERRO: workflow R8 ja existe.' >&2; exit 1; }

echo '=== R8 CRIACAO DO PROJETO DE INTEGRACAO ==='
dotnet new xunit -n HubPedidos.IntegrationTests -f net10.0 --no-restore
rm -f HubPedidos.IntegrationTests/UnitTest1.cs
dotnet sln HubPedidos.sln add HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj

dotnet add HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj package Microsoft.AspNetCore.Mvc.Testing --version 10.0.14
dotnet add HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj package Microsoft.EntityFrameworkCore.Sqlite --version 10.0.14
dotnet add HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj reference \
  HubPedidos.Relatorio4/HubPedidos.Relatorio4.csproj \
  HubPedidos.Relatorio6/HubPedidos.Relatorio6.csproj \
  HubPedidos.Relatorio7/HubPedidos.Relatorio7.csproj

# R6 e R7 possuem Program no namespace global, gerados em assemblies diferentes.
# Alias de referencias evita colisao CS0433 e protege os projetos anteriores.
python3 - <<'PY'
from pathlib import Path
from xml.etree import ElementTree as ET
p=Path('HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj')
root=ET.parse(p).getroot()
aliases={'HubPedidos.Relatorio4.csproj':'R4','HubPedidos.Relatorio6.csproj':'R6','HubPedidos.Relatorio7.csproj':'R7'}
for item in root.findall('.//ProjectReference'):
  incl=item.get('Include','')
  for suffix,alias in aliases.items():
    if incl.endswith(suffix):
      item.set('Aliases',alias)
      break
else:
  pass
pg=ET.SubElement(root,'PropertyGroup')
for key,val in {'EnableNETAnalyzers':'true','AnalysisLevel':'latest','AnalysisMode':'All'}.items():
  ET.SubElement(pg,key).text=val
ET.indent(root,space='  ')
ET.ElementTree(root).write(p,encoding='unicode',xml_declaration=False)
print('ProjectReference aliases: R4, R6 e R7; analisadores .NET ativados.')
PY

cat > HubPedidos.IntegrationTests/.editorconfig <<'EC'
# Escopo restrito ao R8: nao altera a formatacao dos Relatorios 1 a 7.
root = false

[*.cs]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 4
# CA2200: evitar 'throw ex;' que perde o stack trace original.
dotnet_diagnostic.CA2200.severity = error
EC

cat > HubPedidos.IntegrationTests/FabricasDeTeste.cs <<'CS'
extern alias R7;
using System.Data;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Infrastructure;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using R7DbContext = R7::HubPedidos.Relatorio7.R7DbContext;

namespace HubPedidos.IntegrationTests;

// WAF usa host real R7 em 'Testing' e substitui banco persistente por SQLite :memory:.
// Cada instancia tem sua propria conexao aberta e chaves efemeras locais.
public sealed class FabricaR7 : IDisposable
{
    private readonly string _diretorio;
    private readonly string? _credencialAnterior;
    private readonly string? _arquivoDbAnterior;
    private readonly SqliteConnection _conexao;
    private readonly WebApplicationFactory<R7::Program> _fabrica;

    public string ChaveAlice { get; } = "r8-alice-chave-didatica-temporaria";
    public string ChaveBob { get; } = "r8-bob-chave-didatica-temporaria";
    public R7DbContext CriarDbContext() => CriarEscopo().ServiceProvider.GetRequiredService<R7DbContext>();
    public IServiceScope CriarEscopo() => _fabrica.Services.CreateScope();
    public HttpClient CriarCliente() => _fabrica.CreateClient();
    public DbConnectionEstado Conexao => new(_conexao.State, _conexao.DataSource);

    public FabricaR7()
    {
        _diretorio = Path.Combine(Path.GetTempPath(), "hubpedidos-r8-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_diretorio);
        var arquivoChaves = Path.Combine(_diretorio, "tokens.env");
        File.WriteAllLines(arquivoChaves, ["R7_ALICE_KEY=" + ChaveAlice, "R7_BOB_KEY=" + ChaveBob]);
        _credencialAnterior = Environment.GetEnvironmentVariable("R7_CREDENTIALS_FILE");
        _arquivoDbAnterior = Environment.GetEnvironmentVariable("R7_DATABASE_FILE");
        // Necessario antes do codigo de inicializacao original do R7, que le o arquivo de chaves.
        Environment.SetEnvironmentVariable("R7_CREDENTIALS_FILE", arquivoChaves);
        Environment.SetEnvironmentVariable("R7_DATABASE_FILE", Path.Combine(_diretorio, "nao-utilizado.db"));

        _conexao = new SqliteConnection("Data Source=:memory:");
        _conexao.Open();
        _fabrica = new WebApplicationFactory<R7::Program>().WithWebHostBuilder(builder =>
        {
            builder.UseEnvironment("Testing");
            builder.ConfigureTestServices(services =>
            {
                // Remove registros anteriores para que NENHUM DbContext use o banco externo.
                services.RemoveAll<R7DbContext>();
                services.RemoveAll<DbContextOptions<R7DbContext>>();
                services.RemoveAll<IDbContextOptionsConfiguration<R7DbContext>>();
                services.AddDbContext<R7DbContext>(options => options.UseSqlite(_conexao));
            });
        });
    }

    public void Dispose()
    {
        _fabrica.Dispose();
        _conexao.Dispose();
        Environment.SetEnvironmentVariable("R7_CREDENTIALS_FILE", _credencialAnterior);
        Environment.SetEnvironmentVariable("R7_DATABASE_FILE", _arquivoDbAnterior);
        Directory.Delete(_diretorio, recursive: true);
    }
}

public sealed record DbConnectionEstado(ConnectionState Estado, string DataSource);
CS

cat > HubPedidos.IntegrationTests/Relatorio8HttpTests.cs <<'CS'
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
                Id = novoId, Proprietario = "alice", Regiao = "SP", Status = "Processando",
                Total = 42.5m, Versao = 1, AtualizadoEm = DateTimeOffset.UtcNow
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
                db.Pedidos.Add(new PedidoPersistido { Id = id, Proprietario = "alice", Regiao = "SP",
                    Status = "Concluido", Total = 10m, Versao = 1, AtualizadoEm = DateTimeOffset.UtcNow });
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
CS

cat > HubPedidos.IntegrationTests/Relatorio8FilaTests.cs <<'CS'
extern alias R4;
using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Xunit;
using FilaPedidos = R4::HubPedidos.Relatorio4.Pipeline.FilaPedidos;
using IPersistenciaPedido = R4::HubPedidos.Relatorio4.Pipeline.IPersistenciaPedido;
using ProcessarPedidoJob = R4::HubPedidos.Relatorio4.Pipeline.ProcessarPedidoJob;

namespace HubPedidos.IntegrationTests;

public sealed class Relatorio8FilaTests
{
    // Um TaskCompletionSource observa a persistencia fake sem sleeps arbitrarios.
    private sealed class PersistenciaObservada(TaskCompletionSource<Guid> concluido) : IPersistenciaPedido
    {
        public Task GravarAsync(ProcessarPedidoJob pedido, CancellationToken ct)
        {
            concluido.TrySetResult(pedido.PedidoId);
            return Task.CompletedTask;
        }
    }

    [Fact]
    public async Task R8_02_Fila_Post_Http_Executa_Consumidor_Com_Sinal_Deterministico()
    {
        var persistiu = new TaskCompletionSource<Guid>(TaskCreationOptions.RunContinuationsAsynchronously);
        // TEntryPoint esta no assembly da API R4; nao e necessario modificar Program.cs.
        using var fabrica = new WebApplicationFactory<FilaPedidos>().WithWebHostBuilder(builder =>
        {
            builder.ConfigureTestServices(services =>
            {
                services.RemoveAll<IPersistenciaPedido>();
                services.AddScoped<IPersistenciaPedido>(_ => new PersistenciaObservada(persistiu));
            });
        });
        using var cliente = fabrica.CreateClient();
        var id = Guid.NewGuid();
        using var resposta = await cliente.PostAsJsonAsync("/api/pipeline/enfileirar", new { pedidoId = id });
        Assert.Equal(HttpStatusCode.Accepted, resposta.StatusCode);
        // Sinal emitido pela persistencia fake, nao por Task.Delay.
        Assert.Equal(id, await persistiu.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        using var estado = await cliente.GetAsync($"/api/pipeline/status/{id:D}");
        Assert.Equal(HttpStatusCode.OK, estado.StatusCode);
    }
}
CS

mkdir -p HubPedidos.Relatorio8/evidencias .github/workflows
cat > .github/workflows/r8-qualidade.yml <<'YAML'
name: R8 - Qualidade Continua

on:
  push:
    branches: [atividade-08-qualidade, atividade-08-gate-falha]
  pull_request:
    branches: [atividade-08-qualidade]
  workflow_dispatch:

permissions:
  contents: read

jobs:
  validacao:
    name: Build, format, testes e artefatos
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Configurar .NET 10
        uses: actions/setup-dotnet@v4
        with:
          dotnet-version: '10.0.403'
      - name: Restaurar pacotes
        run: dotnet restore HubPedidos.sln
      - name: Build Release e analisadores
        run: dotnet build HubPedidos.sln -c Release --no-restore
      - name: Gate de formatacao da Unidade 8
        run: dotnet format HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj --verify-no-changes --no-restore --severity error
      - name: Testes de integracao com SQLite efemero
        run: dotnet test HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj -c Release --no-build --logger 'trx;LogFileName=r8-integration.trx' --results-directory artifacts
      - name: Regressao sem dependencias externas
        run: dotnet test HubPedidos.Tests/HubPedidos.Tests.csproj -c Release --no-build --filter 'FullyQualifiedName!~Relatorio3DbTests' --logger 'trx;LogFileName=r1-r7-offline.trx' --results-directory artifacts
      - name: Publicar resultados (inclusive em caso de falha)
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: r8-resultados-${{ github.run_number }}
          path: '**/artifacts/*.trx'
          if-no-files-found: warn
YAML

cat > HubPedidos.Relatorio8/ativar_falha_analisador.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
p=HubPedidos.IntegrationTests/ViolacaoTemporaria.cs
[[ ! -e "$p" ]] || { echo "ERRO: $p ja existe." >&2; exit 1; }
cat > "$p" <<'CS'
using System;
namespace HubPedidos.IntegrationTests;
internal static class ViolacaoTemporaria
{
    public static void CausarViolacao()
    {
        try { throw new InvalidOperationException("demonstracao"); }
        catch (Exception ex) { throw ex; } // CA2200: rethrow que perde stack original.
    }
}
CS
printf 'R8.03: violacao CA2200 criada. Execute dotnet build HubPedidos.IntegrationTests -c Release.\n'
echo 'Depois da evidencia remova o arquivo via bash HubPedidos.Relatorio8/limpar_falhas.sh.'
SH

cat > HubPedidos.Relatorio8/ativar_falha_teste.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
p=HubPedidos.IntegrationTests/TesteFalhaTemporaria.cs
[[ ! -e "$p" ]] || { echo "ERRO: $p ja existe." >&2; exit 1; }
cat > "$p" <<'CS'
using Xunit;
namespace HubPedidos.IntegrationTests;
public sealed class TesteFalhaTemporaria
{
    [Fact]
    public void R8_Gate_Deve_Bloquear_Teste_Falho() => Assert.True(false, "Falha deliberada para a evidencia R8.04");
}
CS
printf 'R8.04: teste falho criado. Execute dotnet test HubPedidos.IntegrationTests -c Release.\n'
echo 'Para Actions, publique SOMENTE a branch experimental atividade-08-gate-falha, depois remova e reverta na branch principal.'
SH

cat > HubPedidos.Relatorio8/limpar_falhas.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
rm -f HubPedidos.IntegrationTests/ViolacaoTemporaria.cs HubPedidos.IntegrationTests/TesteFalhaTemporaria.cs
echo 'Arquivos de falha deliberada removidos. Compile e execute novamente para comprovar o gate verde.'
SH

cat > HubPedidos.Relatorio8/roteiro_evidencias.md <<'MD'
# R8 – Qualidade continua | roteiro de capturas

## R8.01 – Fabrica e isolamento
- Abrir `HubPedidos.IntegrationTests/FabricasDeTeste.cs`: `WebApplicationFactory<R7::Program>`, ambiente `Testing`, `ConfigureTestServices` e `RemoveAll`.
- Mostrar `SqliteConnection("Data Source=:memory:")` mantida aberta e descartada pela fixture.
- Mostrar testes `R8_01_...` aprovados; nao existe acesso ao Neon nessa fabrica.

## R8.02 – Contratos e fila
- Abrir `Relatorio8HttpTests.cs`: criacao de dado pela fixture, GET privado, v1/v2, ETag/304, autorizacao, cache.
- Abrir `Relatorio8FilaTests.cs`: POST HTTP R4, persistencia fake e sincronizacao `TaskCompletionSource`, sem esperas arbitrarias.
- `dotnet test HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj -c Release --logger 'console;verbosity=normal'`.

## R8.03 – Analisador e formatacao
- Mostrar `.editorconfig` do R8 com CA2200 em error.
- Rodar `bash HubPedidos.Relatorio8/ativar_falha_analisador.sh` e `dotnet build HubPedidos.IntegrationTests -c Release`.
- CAPTURAR build falhando em CA2200; executar `bash HubPedidos.Relatorio8/limpar_falhas.sh`.
- Rodar `dotnet format HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj --verify-no-changes --no-restore --severity error` para gate verde.

## R8.04 – CI GitHub Actions
- Arquivo `.github/workflows/r8-qualidade.yml`: restore, build, format, testes, artefatos TRX.
- Provar a falha: criar branch a partir de atividade-08-qualidade, incluir falha de teste temporaria, push, print Actions vermelho.
- Reverter a falha temporaria na atividade-08-qualidade e executar workflow; print Actions verde e download/visualizacao artefato TRX.
- IMPORTANTE: teste DB R3 depende Neon; CI offline EXCLUI explicitamente Relatorio3DbTests.
- Na maquina Codespaces com `HUBPEDIDOS_DB` correto executar suite geral (59 anteriores) e R8 separado.

## Limites
- WebApplicationFactory R7 e R6 usam os hosts reais existentes, sem criar uma API fake duplicada.
- R7 nao oferece POST /api/v1/pedidos; a criacao de pedido do R8 ocorre na fixture SQLite e a consulta e via HTTP.
- O POST HTTP real de criacao de trabalho/fila e exercitado no host R4, com fake de persistencia observavel.
- SQLite nao substitui os testes especificos de Npgsql/PostgreSQL.
- Nunca commitar connection strings, .secrets/, bancos .db ou logs com tokens.
MD

chmod +x HubPedidos.Relatorio8/*.sh

echo '=== R8 RESTORE/BUILD/TESTES ESPECIFICOS ==='
dotnet restore HubPedidos.sln
dotnet build HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj -c Release --no-restore
# Limita a normalizacao ao codigo NOVO para preservar relatórios anteriores.
dotnet format HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj --no-restore --severity error
dotnet format HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj --verify-no-changes --no-restore --severity error
dotnet test HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj -c Release --logger 'console;verbosity=normal'

echo '=== R8 PREPARACAO FINALIZADA ==='
echo 'R8.01: FabricaDeTeste.cs / SQLite efemero / Testing.'
echo 'R8.02: HTTP real R4/R6/R7 e fake sinalizada por TaskCompletionSource.'
echo 'R8.03: .editorconfig + ativar_falha_analisador.sh.'
echo 'R8.04: .github/workflows/r8-qualidade.yml + ativar_falha_teste.sh.'
echo 'IMPORTANTE: nao rode este script novamente se houver erro, corrija os arquivos criados.'
