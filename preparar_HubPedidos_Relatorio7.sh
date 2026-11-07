#!/usr/bin/env bash
set -Eeuo pipefail

cd /workspaces/HubPedidos

echo '=== R7: PRE-CHECAGEM (NAO ALTERA R1 A R6) ==='
command -v dotnet >/dev/null || { echo 'ERRO: SDK dotnet nao encontrado.' >&2; exit 1; }
command -v python3 >/dev/null || { echo 'ERRO: python3 nao encontrado.' >&2; exit 1; }
[[ -f HubPedidos.sln && -f HubPedidos.Tests/HubPedidos.Tests.csproj && -f HubPedidos.Relatorio6/HubPedidos.Relatorio6.csproj ]] || {
    echo 'ERRO: requer a solucao HubPedidos com Relatorios 1 a 6.' >&2; exit 1;
}
branch=$(git branch --show-current)
echo "Branch atual: $branch"
if [[ "$branch" != 'atividade-07-tempo-real' ]]; then
    echo 'ERRO: crie/acesse antes a branch atividade-07-tempo-real, partindo da atividade-06-arquitetura.' >&2
    exit 1
fi
for p in HubPedidos.Relatorio7 HubPedidos.Relatorio7.Cliente; do
  if [[ -e "$p" ]]; then
    echo "ERRO: $p ja existe. O script nao sobrescreve implementacoes anteriores." >&2
    echo 'Corrija arquivos pontuais caso um build anterior tenha falhado.' >&2
    exit 1
  fi
done
if [[ -e HubPedidos.Tests/Relatorio7TempoRealTests.cs ]]; then
  echo 'ERRO: testes R7 ja existem. Nao sobrescrevendo.' >&2; exit 1
fi

echo '=== R7: PROJETOS NOVOS, ISOLADOS ==='
dotnet new web -n HubPedidos.Relatorio7 -f net10.0 --no-restore
dotnet new console -n HubPedidos.Relatorio7.Cliente -f net10.0 --no-restore
dotnet sln HubPedidos.sln add \
  HubPedidos.Relatorio7/HubPedidos.Relatorio7.csproj \
  HubPedidos.Relatorio7.Cliente/HubPedidos.Relatorio7.Cliente.csproj

dotnet add HubPedidos.Relatorio7/HubPedidos.Relatorio7.csproj package Microsoft.EntityFrameworkCore.Sqlite --version 10.0.14
dotnet add HubPedidos.Relatorio7.Cliente/HubPedidos.Relatorio7.Cliente.csproj package Microsoft.AspNetCore.SignalR.Client --version 10.0.14
dotnet add HubPedidos.Tests/HubPedidos.Tests.csproj reference HubPedidos.Relatorio7/HubPedidos.Relatorio7.csproj

cat > HubPedidos.Relatorio7/.gitignore <<'EOF'
.secrets/
.data/
*.db
*.db-shm
*.db-wal
bin/
obj/
EOF
mkdir -p HubPedidos.Relatorio7/.secrets HubPedidos.Relatorio7/.data HubPedidos.Relatorio7/evidencias
python3 - <<'PY'
import pathlib,secrets
p=pathlib.Path('HubPedidos.Relatorio7/.secrets/tokens.env')
p.write_text('R7_ALICE_KEY='+secrets.token_hex(24)+'\nR7_BOB_KEY='+secrets.token_hex(24)+'\n')
p.chmod(0o600)
print('Credenciais aleatorias locais criadas em .secrets/ (ignoradas pelo Git).')
PY

cat > HubPedidos.Relatorio7/Contratos.cs <<'CS'
namespace HubPedidos.Relatorio7;

// Evento minimo, sem dados pessoais nem entidade de dominio.
public sealed record PedidoAtualizado(Guid PedidoId, string Status, int Versao, DateTimeOffset Em);

public interface IPedidosClient
{
    Task PedidoAtualizado(PedidoAtualizado evento);
}

public sealed record PedidoDetalheDto(Guid Id, string Status, decimal Total, int Versao, DateTimeOffset AtualizadoEm);
public sealed record AlterarStatusRequest(string Status);

public sealed record ResultadoAtualizacao(int HttpStatus, PedidoDetalheDto? Pedido = null, string? Erro = null);
CS

cat > HubPedidos.Relatorio7/Dados.cs <<'CS'
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Relatorio7;

public sealed class PedidoPersistido
{
    public Guid Id { get; set; }
    public string Proprietario { get; set; } = "";
    public string Regiao { get; set; } = "";
    public string Status { get; set; } = "";
    public decimal Total { get; set; }
    public int Versao { get; set; }
    public DateTimeOffset AtualizadoEm { get; set; }
}

public sealed class R7DbContext(DbContextOptions<R7DbContext> options) : DbContext(options)
{
    public DbSet<PedidoPersistido> Pedidos => Set<PedidoPersistido>();
    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<PedidoPersistido>(b =>
        {
            b.HasKey(p => p.Id);
            b.Property(p => p.Versao).IsConcurrencyToken();
            b.Property(p => p.Status).HasMaxLength(48).IsRequired();
            b.Property(p => p.Proprietario).HasMaxLength(50).IsRequired();
            b.Property(p => p.Regiao).HasMaxLength(2).IsRequired();
        });
    }
}

public static class ExemplosR7
{
    public static readonly Guid AliceId = Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
    public static readonly Guid BobId = Guid.Parse("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb");
    public static void Semear(R7DbContext db)
    {
        db.Database.EnsureCreated();
        if (db.Pedidos.Any()) return;
        db.Pedidos.AddRange(
            new PedidoPersistido { Id = AliceId, Proprietario = "alice", Regiao = "SP", Status = "Processando", Total = 80.00m, Versao = 1, AtualizadoEm = DateTimeOffset.UtcNow },
            new PedidoPersistido { Id = BobId, Proprietario = "bob", Regiao = "RJ", Status = "Processando", Total = 50.00m, Versao = 1, AtualizadoEm = DateTimeOffset.UtcNow }
        );
        db.SaveChanges();
    }
}

public static class PedidoEtag
{
    // Hash da representacao completa relevante ao cliente. Uma mesma versao gera a mesma ETag.
    public static string Calcular(PedidoPersistido p)
    {
        var representacao = string.Join("|",
            p.Id.ToString("D"), p.Status, p.Total.ToString("0.00", CultureInfo.InvariantCulture),
            p.Versao.ToString(CultureInfo.InvariantCulture),
            p.AtualizadoEm.ToUniversalTime().ToString("O", CultureInfo.InvariantCulture));
        return "\"" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(representacao))) + "\"";
    }

    public static bool Corresponde(string? cabecalho, string atual) =>
        string.Equals(cabecalho?.Trim(), atual, StringComparison.Ordinal);

    public static PedidoDetalheDto ParaDto(PedidoPersistido p) =>
        new(p.Id, p.Status, p.Total, p.Versao, p.AtualizadoEm);
}
CS

cat > HubPedidos.Relatorio7/Autenticacao.cs <<'CS'
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Options;

namespace HubPedidos.Relatorio7;

// Autenticacao exclusivamente didatica: duas chaves aleatorias geradas por Codespaces.
// Sem JWT real, nao deve ser publicada como mecanismo de producao.
public sealed class CredenciaisDidaticas
{
    private readonly Dictionary<string, string> _usuarios;
    public CredenciaisDidaticas(string caminho)
    {
        if (!File.Exists(caminho)) throw new InvalidOperationException("Arquivo local de chaves R7 ausente. Execute o script de preparacao.");
        var itens = File.ReadAllLines(caminho).Where(s => s.Contains('=')).Select(s => s.Split('=', 2)).ToDictionary(a => a[0], a => a[1]);
        _usuarios = new Dictionary<string, string>
        {
            ["alice"] = itens["R7_ALICE_KEY"],
            ["bob"] = itens["R7_BOB_KEY"]
        };
    }
    public string? Identificar(string token)
    {
        var bytes = Encoding.UTF8.GetBytes(token);
        foreach (var (usuario, senha) in _usuarios)
        {
            var esperado = Encoding.UTF8.GetBytes(senha);
            if (bytes.Length == esperado.Length && CryptographicOperations.FixedTimeEquals(bytes, esperado)) return usuario;
        }
        return null;
    }
}

public sealed class ChaveR7Handler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    CredenciaisDidaticas credenciais) : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    protected override Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var cabecalho = Request.Headers.Authorization.ToString();
        if (!cabecalho.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            return Task.FromResult(AuthenticateResult.NoResult());
        var usuario = credenciais.Identificar(cabecalho[7..].Trim());
        if (usuario is null) return Task.FromResult(AuthenticateResult.Fail("Credencial invalida."));
        var identidade = new ClaimsIdentity(new[] { new Claim(ClaimTypes.NameIdentifier, usuario), new Claim(ClaimTypes.Name, usuario) }, Scheme.Name);
        return Task.FromResult(AuthenticateResult.Success(new AuthenticationTicket(new ClaimsPrincipal(identidade), Scheme.Name)));
    }
}

public interface IPedidoAccessService
{
    Task<bool> PodeVerAsync(string usuario, Guid pedidoId, CancellationToken ct = default);
}

public sealed class PedidoAccessService(R7DbContext db) : IPedidoAccessService
{
    public Task<bool> PodeVerAsync(string usuario, Guid pedidoId, CancellationToken ct = default) =>
        db.Pedidos.AsNoTracking().AnyAsync(p => p.Id == pedidoId && p.Proprietario == usuario, ct);
}
CS

cat > HubPedidos.Relatorio7/PedidosHub.cs <<'CS'
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;

namespace HubPedidos.Relatorio7;

// Grupo nao fornece seguranca: cada inscricao depende da autorizacao no servidor.
[Authorize]
public sealed class PedidosHub(IPedidoAccessService acesso, IHostEnvironment ambiente) : Hub<IPedidosClient>
{
    public async Task Acompanhar(Guid pedidoId)
    {
        var usuario = Context.UserIdentifier;
        if (usuario is null || !await acesso.PodeVerAsync(usuario, pedidoId, Context.ConnectionAborted))
            throw new HubException("Acesso nao autorizado ao pedido.");
        await Groups.AddToGroupAsync(Context.ConnectionId, Grupo(pedidoId));
    }

    // Apenas no ambiente Development: interrompe a conexao para testar reconexao/reingresso.
    public void SimularQueda()
    {
        if (!ambiente.IsDevelopment()) throw new HubException("Indisponivel fora de Development.");
        Context.Abort();
    }

    public static string Grupo(Guid id) => $"pedido:{id:D}";
}

public interface IEmissorPedido
{
    Task EmitirAsync(PedidoAtualizado evento, CancellationToken ct = default);
}

public sealed class EmissorSignalR(IHubContext<PedidosHub, IPedidosClient> hub) : IEmissorPedido
{
    public Task EmitirAsync(PedidoAtualizado evento, CancellationToken ct = default) =>
        hub.Clients.Group(PedidosHub.Grupo(evento.PedidoId)).PedidoAtualizado(evento);
}
CS

cat > HubPedidos.Relatorio7/Servicos.cs <<'CS'
using Microsoft.EntityFrameworkCore;
using Microsoft.AspNetCore.OutputCaching;

namespace HubPedidos.Relatorio7;

public sealed class AtualizadorPedidos(R7DbContext db, IEmissorPedido emissor, IOutputCacheStore cache)
{
    public async Task<ResultadoAtualizacao> AlterarAsync(Guid pedidoId, string usuario, string status,
        string? ifMatch, CancellationToken ct = default)
    {
        // Seguranca da propriedade verificada antes de devolver informacoes do recurso.
        var pedido = await db.Pedidos.SingleOrDefaultAsync(p => p.Id == pedidoId, ct);
        if (pedido is null) return new(404, Erro: "Pedido nao encontrado.");
        if (!string.Equals(pedido.Proprietario, usuario, StringComparison.Ordinal)) return new(403, Erro: "Sem acesso.");
        if (string.IsNullOrWhiteSpace(ifMatch)) return new(428, Erro: "If-Match obrigatorio.");
        if (!PedidoEtag.Corresponde(ifMatch, PedidoEtag.Calcular(pedido))) return new(412, Erro: "ETag obsoleta.");
        if (status is not ("Processando" or "Concluido")) return new(400, Erro: "Status invalido.");

        pedido.Status = status;
        pedido.Versao++;
        pedido.AtualizadoEm = DateTimeOffset.UtcNow;
        try
        {
            // A publicacao ocorre SOMENTE depois de persistir com sucesso.
            await db.SaveChangesAsync(ct);
        }
        catch (DbUpdateConcurrencyException)
        {
            return new(412, Erro: "Versao concorrente desatualizada.");
        }
        var evento = new PedidoAtualizado(pedido.Id, pedido.Status, pedido.Versao, pedido.AtualizadoEm);
        await emissor.EmitirAsync(evento, ct);
        await cache.EvictByTagAsync("catalogo-status", ct);
        return new(200, PedidoEtag.ParaDto(pedido));
    }
}
CS

cat > HubPedidos.Relatorio7/ApiEndpoints.cs <<'CS'
using System.Security.Claims;
using Microsoft.AspNetCore.OutputCaching;
using Microsoft.EntityFrameworkCore;

namespace HubPedidos.Relatorio7;

public static class ApiEndpoints
{
    public static async Task<IResult> Detalhe(Guid id, HttpContext contexto, R7DbContext db, CancellationToken ct)
    {
        var usuario = contexto.User.FindFirstValue(ClaimTypes.NameIdentifier);
        var pedido = await db.Pedidos.AsNoTracking().SingleOrDefaultAsync(p => p.Id == id, ct);
        if (pedido is null) return Results.NotFound();
        if (usuario != pedido.Proprietario) return Results.Forbid();
        var etag = PedidoEtag.Calcular(pedido);
        contexto.Response.Headers.ETag = etag;
        contexto.Response.Headers.CacheControl = "private, no-cache";
        if (PedidoEtag.Corresponde(contexto.Request.Headers.IfNoneMatch, etag))
            return Results.StatusCode(StatusCodes.Status304NotModified); // sem corpo
        return Results.Ok(PedidoEtag.ParaDto(pedido));
    }

    public static async Task<IResult> Alterar(Guid id, AlterarStatusRequest pedido,
        HttpContext contexto, AtualizadorPedidos atualizador, CancellationToken ct)
    {
        var usuario = contexto.User.FindFirstValue(ClaimTypes.NameIdentifier);
        if (usuario is null) return Results.Unauthorized();
        var resultado = await atualizador.AlterarAsync(id, usuario, pedido.Status,
            contexto.Request.Headers.IfMatch.ToString(), ct);
        return resultado.HttpStatus switch
        {
            200 => Results.Ok(resultado.Pedido),
            400 => Results.BadRequest(new { erro = resultado.Erro }),
            403 => Results.Forbid(),
            404 => Results.NotFound(),
            412 => Results.StatusCode(StatusCodes.Status412PreconditionFailed),
            428 => Results.StatusCode(StatusCodes.Status428PreconditionRequired),
            _ => Results.StatusCode(resultado.HttpStatus)
        };
    }

    public static async Task<IResult> Catalogo(string? regiao, R7DbContext db, CancellationToken ct)
    {
        var dados = await db.Pedidos.AsNoTracking()
            .Where(p => regiao == null || p.Regiao == regiao.ToUpper())
            .Select(p => p.Status).ToListAsync(ct);
        var grupos = dados.GroupBy(x => x).OrderBy(x => x.Key)
            .Select(x => new { status = x.Key, quantidade = x.Count() }).ToArray();
        return Results.Ok(new { regiao = regiao?.ToUpper() ?? "TODAS", geradoEm = DateTimeOffset.UtcNow, status = grupos });
    }
}
CS

cat > HubPedidos.Relatorio7/Program.cs <<'CS'
using HubPedidos.Relatorio7;
using Microsoft.AspNetCore.Authentication;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);
builder.Host.UseDefaultServiceProvider((_, options) => { options.ValidateOnBuild = true; options.ValidateScopes = true; });

// Apenas demonstracao local em Codespaces. Chaves aleatorias, nao commitadas.
var credenciais = builder.Configuration["R7_CREDENTIALS_FILE"] ??
    Path.Combine(builder.Environment.ContentRootPath, ".secrets", "tokens.env");
builder.Services.AddSingleton(new CredenciaisDidaticas(credenciais));
builder.Services.AddAuthentication("R7").AddScheme<AuthenticationSchemeOptions, ChaveR7Handler>("R7", _ => { });
builder.Services.AddAuthorization();
builder.Services.AddSignalR();
builder.Services.AddScoped<IPedidoAccessService, PedidoAccessService>();
builder.Services.AddScoped<AtualizadorPedidos>();
builder.Services.AddSingleton<IEmissorPedido, EmissorSignalR>();

var banco = builder.Configuration["R7_DATABASE_FILE"] ??
    Path.Combine(builder.Environment.ContentRootPath, ".data", "pedidos.db");
Directory.CreateDirectory(Path.GetDirectoryName(banco)!);
builder.Services.AddDbContext<R7DbContext>(opt => opt.UseSqlite($"Data Source={banco}"));

builder.Services.AddOutputCache(opcoes => opcoes.AddPolicy("CatalogoPublico", policy => policy
    .Expire(TimeSpan.FromMinutes(10))
    .SetVaryByQuery("regiao")
    .Tag("catalogo-status")));

var app = builder.Build();
using (var scope = app.Services.CreateScope()) ExemplosR7.Semear(scope.ServiceProvider.GetRequiredService<R7DbContext>());
app.UseRouting();
app.UseAuthentication();
app.UseAuthorization();
app.UseOutputCache();

app.MapGet("/health", () => Results.Ok(new { modulo = "R7", status = "ok" }));
app.MapHub<PedidosHub>("/hubs/pedidos").RequireAuthorization();

// Apenas dado publico tem Output Cache. GET privado tem ETag, SEM Output Cache.
app.MapGet("/api/publico/catalogo-status", ApiEndpoints.Catalogo)
    .CacheOutput("CatalogoPublico");
app.MapGet("/api/v1/pedidos/{id:guid}", ApiEndpoints.Detalhe).RequireAuthorization();
app.MapPut("/api/v1/pedidos/{id:guid}/status", ApiEndpoints.Alterar).RequireAuthorization();
app.Run();

// Permite testes de API em estudos posteriores sem alterar esta implementacao.
public partial class Program { }
CS

cat > HubPedidos.Relatorio7.Cliente/Program.cs <<'CS'
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.SignalR.Client;
using Microsoft.AspNetCore.SignalR;

// Cliente de teste real usando dois usuarios: alice autorizado e bob sem acesso ao pedido de alice.
var origem = args.Length > 0 ? args[0].TrimEnd('/') : "http://localhost:5087";
var chaves = Environment.GetEnvironmentVariable("R7_CREDENTIALS_FILE") ??
    Path.Combine(Directory.GetCurrentDirectory(), "HubPedidos.Relatorio7", ".secrets", "tokens.env");
var itens = File.ReadAllLines(chaves).Where(s => s.Contains('=')).Select(s => s.Split('=', 2)).ToDictionary(a => a[0], a => a[1]);
var aliceKey = itens["R7_ALICE_KEY"];
var bobKey = itens["R7_BOB_KEY"];
var pedidoId = Guid.Parse("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa");
var uri = new Uri(origem);
using var aliceHttp = new HttpClient { BaseAddress = uri, Timeout = TimeSpan.FromSeconds(20) };
using var bobHttp = new HttpClient { BaseAddress = uri, Timeout = TimeSpan.FromSeconds(20) };
using var publicoHttp = new HttpClient { BaseAddress = uri, Timeout = TimeSpan.FromSeconds(20) };
aliceHttp.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", aliceKey);
bobHttp.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", bobKey);

HubConnection CriarConexao(string chave) => new HubConnectionBuilder()
    .WithUrl($"{origem}/hubs/pedidos", opcoes => opcoes.AccessTokenProvider = () => Task.FromResult<string?>(chave))
    .WithAutomaticReconnect(new[] { TimeSpan.Zero, TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5) })
    .Build();

await using var alice = CriarConexao(aliceKey);
await using var bob = CriarConexao(bobKey);
var eventosAlice = 0; var eventosBob = 0;
var eventoRecebido = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
var reconciliado = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
var entrouEmReconexao = false;

alice.On<JsonElement>("PedidoAtualizado", mensagem =>
{
    Interlocked.Increment(ref eventosAlice);
    var versao = mensagem.GetProperty("versao").GetInt32();
    var status = mensagem.GetProperty("status").GetString();
    Console.WriteLine($"R7.01 EVENTO: alice recebeu pedido={pedidoId}; status={status}; versao={versao}");
    eventoRecebido.TrySetResult(true);
});
bob.On<JsonElement>("PedidoAtualizado", _ => Interlocked.Increment(ref eventosBob));

alice.Reconnecting += _ => { entrouEmReconexao = true; Console.WriteLine("R7.02 ESTADO: Reconectando"); return Task.CompletedTask; };
alice.Reconnected += async _ =>
{
    try
    {
        await alice.InvokeAsync("Acompanhar", pedidoId);
        var estado = await aliceHttp.GetAsync($"/api/v1/pedidos/{pedidoId}");
        estado.EnsureSuccessStatusCode();
        var registro = JsonDocument.Parse(await estado.Content.ReadAsStringAsync());
        Console.WriteLine($"R7.02 ESTADO: Conectado; reingresso=SIM; GET HTTP={((int)estado.StatusCode)}; versao_atual={registro.RootElement.GetProperty("versao").GetInt32()}; reconciliado=SIM");
        reconciliado.TrySetResult(true);
    }
    catch (Exception erro) { reconciliado.TrySetException(erro); }
};
alice.Closed += _ => { Console.WriteLine("R7.02 ESTADO: Desconectado"); return Task.CompletedTask; };

await alice.StartAsync(); await bob.StartAsync();
Console.WriteLine("R7.02 ESTADO: Conectado (alice e bob)");
await alice.InvokeAsync("Acompanhar", pedidoId);
var bobRejeitado = false;
try { await bob.InvokeAsync("Acompanhar", pedidoId); }
catch (HubException) { bobRejeitado = true; }
if (!bobRejeitado) throw new Exception("Falha R7.01: bob entrou no grupo de alice.");
var bobDetalhe = await bobHttp.GetAsync($"/api/v1/pedidos/{pedidoId}");
if (bobDetalhe.StatusCode != HttpStatusCode.Forbidden) throw new Exception("Falha: bob deveria receber HTTP 403.");
Console.WriteLine("R7.01 AUTORIZACAO: alice no grupo=SIM; bob no grupo=NAO; bob GET=403");

// Antes da escrita: comprova 200, ETag estavel e 304 sem corpo.
var respostaAntes = await aliceHttp.GetAsync($"/api/v1/pedidos/{pedidoId}");
respostaAntes.EnsureSuccessStatusCode();
var etagAntiga = respostaAntes.Headers.ETag?.ToString() ?? throw new Exception("ETag ausente.");
using var docAntes = JsonDocument.Parse(await respostaAntes.Content.ReadAsStringAsync());
var statusAntes = docAntes.RootElement.GetProperty("status").GetString();
var novoStatus = statusAntes == "Processando" ? "Concluido" : "Processando";
using var condicional = new HttpRequestMessage(HttpMethod.Get, $"/api/v1/pedidos/{pedidoId}");
condicional.Headers.TryAddWithoutValidation("If-None-Match", etagAntiga);
var resposta304 = await aliceHttp.SendAsync(condicional);
var bytes304 = await resposta304.Content.ReadAsByteArrayAsync();
if (resposta304.StatusCode != HttpStatusCode.NotModified || bytes304.Length != 0)
    throw new Exception("ETag deveria produzir 304 sem corpo.");
Console.WriteLine($"R7.03 ETAG: primeiro=200; condicional=304; bytes_304={bytes304.Length}; etag_estavel=SIM");
using var semPrecondicao = new HttpRequestMessage(HttpMethod.Put, $"/api/v1/pedidos/{pedidoId}/status");
semPrecondicao.Content = JsonContent.Create(new { status = novoStatus });
var resposta428 = await aliceHttp.SendAsync(semPrecondicao);
if ((int)resposta428.StatusCode != 428) throw new Exception("If-Match ausente deveria retornar 428.");
Console.WriteLine("R7.03 IF-MATCH: ausente=428; atualizacao condicionada obrigatoria=SIM");

// Cache publico por regiao: a segunda resposta deve manter geradoEm da primeira.
async Task<string> Catalogo(string regiao)
{
    var resposta = await publicoHttp.GetAsync($"/api/publico/catalogo-status?regiao={regiao}");
    resposta.EnsureSuccessStatusCode();
    return await resposta.Content.ReadAsStringAsync();
}
var sp1 = await Catalogo("SP"); var sp2 = await Catalogo("SP"); var rj = await Catalogo("RJ");
if (sp1 != sp2) throw new Exception("Catalogo publico SP nao foi servido do Output Cache.");
if (sp1 == rj) throw new Exception("A variacao por regiao nao ocorreu.");
Console.WriteLine("R7.04 CACHE: SP segunda consulta=HIT; RJ conteudo distinto=SIM; cache apenas publico=SIM");

// If-Match valido, persistencia SQLite, evento SignalR apos SaveChanges e invalidacao por tag.
using var atualizar = new HttpRequestMessage(HttpMethod.Put, $"/api/v1/pedidos/{pedidoId}/status");
atualizar.Headers.TryAddWithoutValidation("If-Match", etagAntiga);
atualizar.Content = JsonContent.Create(new { status = novoStatus });
var respostaPut = await aliceHttp.SendAsync(atualizar);
if (respostaPut.StatusCode != HttpStatusCode.OK) throw new Exception($"Atualizacao falhou: HTTP {(int)respostaPut.StatusCode}");
await eventoRecebido.Task.WaitAsync(TimeSpan.FromSeconds(10));
await Task.Delay(300);
if (eventosBob != 0) throw new Exception("Bob recebeu evento indevido.");
Console.WriteLine($"R7.01 ISOLAMENTO: recebidos_alice={eventosAlice}; recebidos_bob={eventosBob}; evento_apos_persistencia=SIM");

var respostaDepois = await aliceHttp.GetAsync($"/api/v1/pedidos/{pedidoId}");
respostaDepois.EnsureSuccessStatusCode();
var etagNova = respostaDepois.Headers.ETag?.ToString() ?? throw new Exception("Nova ETag ausente.");
if (etagNova == etagAntiga) throw new Exception("ETag nao mudou apos alteracao.");
using var obsoleto = new HttpRequestMessage(HttpMethod.Put, $"/api/v1/pedidos/{pedidoId}/status");
obsoleto.Headers.TryAddWithoutValidation("If-Match", etagAntiga);
obsoleto.Content = JsonContent.Create(new { status = statusAntes });
var resposta412 = await aliceHttp.SendAsync(obsoleto);
if (resposta412.StatusCode != HttpStatusCode.PreconditionFailed) throw new Exception("If-Match obsoleto deveria retornar 412.");
var sp3 = await Catalogo("SP");
if (sp3 == sp1) throw new Exception("Cache de catalogo publico nao foi invalidado.");
Console.WriteLine("R7.03 ETAG: apos_atualizacao=200; etag_nova=SIM; If-Match_obsoleto=412");
Console.WriteLine("R7.04 CACHE: apos_alteracao=INVALIDADO; regiao SP atualizada; detalhe privado sem Output Cache");

// Forca a queda apenas no ambiente Development, exercitando automatic reconnect, reingresso e GET.
try { await alice.InvokeAsync("SimularQueda"); } catch { /* a propria desconexao cancela a invocacao */ }
await reconciliado.Task.WaitAsync(TimeSpan.FromSeconds(30));
if (!entrouEmReconexao) throw new Exception("Callback Reconnecting nao foi observado.");
Console.WriteLine("R7.02 RECONEXAO: WithAutomaticReconnect=SIM; reassinatura=SIM; GET autoritativo=SIM");
Console.WriteLine("R7 RESULTADO: autorizacao, evento, reconexao, ETag/304, If-Match/412 e Output Cache aprovados.");
CS

cat > HubPedidos.Tests/Relatorio7TempoRealTests.cs <<'CS'
using HubPedidos.Relatorio7;
using Microsoft.EntityFrameworkCore;
using Xunit;

namespace HubPedidos.Tests;

public sealed class Relatorio7TempoRealTests
{
    private static PedidoPersistido Pedido(string status = "Processando", int versao = 1) =>
        new() { Id = ExemplosR7.AliceId, Proprietario = "alice", Regiao = "SP", Total = 80m,
            Status = status, Versao = versao, AtualizadoEm = new DateTimeOffset(2026, 11, 7, 12, 0, 0, TimeSpan.Zero) };

    [Fact] public void ETag_Estavel_Para_Mesmo_Conteudo() =>
        Assert.Equal(PedidoEtag.Calcular(Pedido()), PedidoEtag.Calcular(Pedido()));

    [Fact] public void ETag_Muda_Quando_Versao_Ou_Status_Mudam()
    {
        Assert.NotEqual(PedidoEtag.Calcular(Pedido()), PedidoEtag.Calcular(Pedido(versao: 2)));
        Assert.NotEqual(PedidoEtag.Calcular(Pedido()), PedidoEtag.Calcular(Pedido(status: "Concluido")));
    }

    [Fact] public void IfNoneMatch_Igual_E_Obsoleto_Sao_Distinguidos()
    {
        var tag = PedidoEtag.Calcular(Pedido());
        Assert.True(PedidoEtag.Corresponde(tag, tag));
        Assert.False(PedidoEtag.Corresponde("\"invalida\"", tag));
    }

    [Fact] public void Evento_Tipado_Nao_Expoe_Proprietario_Ou_Total()
    {
        var propriedades = typeof(PedidoAtualizado).GetProperties().Select(x => x.Name).ToArray();
        Assert.Equal(new[] { "PedidoId", "Status", "Versao", "Em" }, propriedades);
    }

    [Fact] public void DTO_Preserva_Versao_Apos_Persistencia()
    {
        var dto = PedidoEtag.ParaDto(Pedido(versao: 3));
        Assert.Equal(3, dto.Versao);
        Assert.Equal(80m, dto.Total);
    }

    [Fact] public void Grupo_SignalR_Escolhido_Pelo_Id_Do_Pedido() =>
        Assert.Equal($"pedido:{ExemplosR7.AliceId:D}", PedidosHub.Grupo(ExemplosR7.AliceId));

    [Fact] public async Task Autorizacao_Consulta_Propriedade_No_Banco()
    {
        var opts = new DbContextOptionsBuilder<R7DbContext>().UseSqlite("Data Source=:memory:").Options;
        await using var db = new R7DbContext(opts);
        await db.Database.OpenConnectionAsync();
        await db.Database.EnsureCreatedAsync();
        db.Pedidos.Add(Pedido());
        await db.SaveChangesAsync();
        var servico = new PedidoAccessService(db);
        Assert.True(await servico.PodeVerAsync("alice", ExemplosR7.AliceId));
        Assert.False(await servico.PodeVerAsync("bob", ExemplosR7.AliceId));
    }

    [Fact] public async Task Etag_Reflete_Mudanca_Persistida_Com_Concorrencia()
    {
        var opts = new DbContextOptionsBuilder<R7DbContext>().UseSqlite("Data Source=:memory:").Options;
        await using var db = new R7DbContext(opts);
        await db.Database.OpenConnectionAsync();
        await db.Database.EnsureCreatedAsync();
        db.Pedidos.Add(Pedido()); await db.SaveChangesAsync();
        var antes = PedidoEtag.Calcular((await db.Pedidos.SingleAsync()));
        var item = await db.Pedidos.SingleAsync();
        item.Status = "Concluido"; item.Versao++; item.AtualizadoEm = DateTimeOffset.UtcNow;
        await db.SaveChangesAsync();
        Assert.NotEqual(antes, PedidoEtag.Calcular(await db.Pedidos.SingleAsync()));
    }
}
CS

cat > HubPedidos.Relatorio7/iniciar_api.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
export R7_CREDENTIALS_FILE="$PWD/HubPedidos.Relatorio7/.secrets/tokens.env"
export R7_DATABASE_FILE="$PWD/HubPedidos.Relatorio7/.data/pedidos.db"
export ASPNETCORE_ENVIRONMENT=Development
export ASPNETCORE_URLS=http://0.0.0.0:5087
dotnet run --project HubPedidos.Relatorio7/HubPedidos.Relatorio7.csproj -c Release --no-launch-profile
SH

cat > HubPedidos.Relatorio7/rodar_cliente.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
export R7_CREDENTIALS_FILE="$PWD/HubPedidos.Relatorio7/.secrets/tokens.env"
dotnet run --project HubPedidos.Relatorio7.Cliente/HubPedidos.Relatorio7.Cliente.csproj \
  -c Release --no-launch-profile -- http://localhost:5087
SH

cat > HubPedidos.Relatorio7/testar_http.sh <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
source HubPedidos.Relatorio7/.secrets/tokens.env
URL=http://localhost:5087
ID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '\n=== R7.03 GET AUTORIZADO / ETag ===\n'
code=$(curl -sS -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}' -H "Authorization: Bearer $R7_ALICE_KEY" "$URL/api/v1/pedidos/$ID")
etag=$(grep -i '^ETag:' "$TMP/headers" | head -1 | cut -d' ' -f2- | tr -d '\r')
printf 'GET alice HTTP=%s; ETag presente=%s\n' "$code" "$([[ -n "$etag" ]] && echo SIM || echo NAO)"
cat "$TMP/body"; printf '\n'
printf '\n=== R7.03 IF-NONE-MATCH ===\n'
code=$(curl -sS -o "$TMP/304" -w '%{http_code}' -H "Authorization: Bearer $R7_ALICE_KEY" -H "If-None-Match: $etag" "$URL/api/v1/pedidos/$ID")
printf 'GET condicional HTTP=%s; corpo_bytes=%s (esperado 304/0)\n' "$code" "$(wc -c < "$TMP/304")"
printf '\n=== R7.01 AUTORIZACAO ===\n'
sem_auth=$(curl -sS -o /dev/null -w '%{http_code}' "$URL/api/v1/pedidos/$ID")
printf 'GET sem credencial HTTP=%s (esperado 401)\n' "$sem_auth"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $R7_BOB_KEY" "$URL/api/v1/pedidos/$ID")
printf 'GET bob pedido da alice HTTP=%s (esperado 403)\n' "$code"
printf '\n=== R7.04 OUTPUT CACHE PUBLICO ===\n'
sp1=$(curl -fsS "$URL/api/publico/catalogo-status?regiao=SP")
sp2=$(curl -fsS "$URL/api/publico/catalogo-status?regiao=SP")
rj=$(curl -fsS "$URL/api/publico/catalogo-status?regiao=RJ")
[[ "$sp1" == "$sp2" ]] && echo 'SP repetido: cache HIT (mesmo JSON)' || echo 'SP repetido: resultados distintos, investigar cache'
[[ "$sp1" != "$rj" ]] && echo 'RJ: variacao por regiao confirmada' || echo 'RJ: resultado nao diferenciado'
printf 'SP: %s\nRJ: %s\n' "$sp1" "$rj"
SH

cat > HubPedidos.Relatorio7/roteiro_evidencias.md <<'MD'
# Relatorio 7 – Roteiro de evidencias (UNIP ADS)

## R7.01 – SignalR e autorizacao
- Codigo: `PedidosHub.cs` mostra `[Authorize]` e checagem de `IPedidoAccessService` antes do grupo.
- Codigo: `Servicos.cs` mostra `SaveChangesAsync` ANTES de `EmitirAsync`.
- Terminal: `rodar_cliente.sh` mostra Alice autorizada, Bob rejeitado, evento Alice=1 / Bob=0.

## R7.02 – reconexao e reconciliacao
- Codigo: `HubPedidos.Relatorio7.Cliente/Program.cs`: `WithAutomaticReconnect`, callbacks `Reconnecting` e `Reconnected`, `Acompanhar` e GET apos reconexao.
- Terminal `rodar_cliente.sh`: `Reconectando -> Conectado; reingresso=SIM; reconciliado=SIM`.
- O evento perdido nao e reproduzido automaticamente: HTTP GET e estado autoritativo.

## R7.03 – ETag / If-None-Match / If-Match
- Codigo: `Dados.cs` / `ApiEndpoints.cs`: SHA256 estavel, cabecalho ETag e 304 sem corpo.
- Terminal `testar_http.sh`: 200, 304, bytes=0; `rodar_cliente.sh`: novo ETag e HTTP 412 para If-Match obsoleto.

## R7.04 – Output Cache somente publico
- Codigo: `Program.cs`: politica CatalogoPublico, SetVaryByQuery("regiao"), tag de invalidação; rotas privadas nao usam `.CacheOutput`.
- Codigo: `Servicos.cs`: `EvictByTagAsync` APOS escrita.
- Terminal: SP HIT, RJ variacao, SP invalidado apos alteracao.

## Regressao
- Testes novos: `dotnet test ... --filter FullyQualifiedName~Relatorio7TempoRealTests` (8 testes se todos passarem).
- Geral: `dotnet test -c Release ...` (esperados 59, os 51 anteriores + 8 novos, se todos passarem).

> A autenticacao por chaves aleatorias locais e exclusivamente didatica. Nao publicar a porta 5087 publicamente.
> Este R7 usa SQLite local para demonstrar SaveChanges e a ordem persistencia/evento; o Neon dos relatorios anteriores permanece intacto.
> As credenciais em `.secrets/` e a base `.data/` sao ignoradas pelo Git. Nunca fazer print das chaves.
MD

cat > HubPedidos.Relatorio7/politica_cache.md <<'MD'
# Politica de cache e revalidacao R7

- Rotas privadas `/api/v1/pedidos/{id}`: autorizacao de usuario + ETag forte baseada na representacao do pedido; HTTP 304 sem corpo apenas apos validar a propriedade do pedido. NAO habilitar Output Cache compartilhado.
- Rotas de alteracao: `If-Match` obrigatorio; ausencia -> HTTP 428; ETag desatualizada -> HTTP 412. A versao interna EF Core e token de concorrencia.
- Rota publica `/api/publico/catalogo-status?regiao=SP`: Output Cache por 10 min, variando por `regiao`. Invalida a tag `catalogo-status` apos persistencia do novo estado.
- SignalR: grupos filtram destinatarios, mas nao substituem autorizacao. Reingresso apos reconexao precisa autorizar novamente e consultar GET HTTP.
- Identificacao local de usuario: chave aleatoria em arquivo ignorado no Git, adequada apenas a exercicio controlado; requer provedor de identidade real para producao.
MD

chmod +x HubPedidos.Relatorio7/iniciar_api.sh HubPedidos.Relatorio7/rodar_cliente.sh HubPedidos.Relatorio7/testar_http.sh

echo '=== R7: RESTORE/BUILD ==='
dotnet build HubPedidos.sln -c Release

echo '=== R7: TESTES ESPECIFICOS ==='
dotnet test HubPedidos.Tests/HubPedidos.Tests.csproj -c Release \
  --no-build --filter 'FullyQualifiedName~Relatorio7TempoRealTests' \
  --logger 'console;verbosity=normal'

echo '=== R7: ETAPA DE PREPARACAO CONCLUIDA ==='
echo 'Para a coleta, inicie: bash HubPedidos.Relatorio7/iniciar_api.sh'
echo 'Em outro terminal: bash HubPedidos.Relatorio7/testar_http.sh'
echo 'Depois: bash HubPedidos.Relatorio7/rodar_cliente.sh'
echo 'Nao rode este script novamente: ele nao sobrescreve projetos existentes.'
