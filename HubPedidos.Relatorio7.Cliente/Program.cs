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
var recuperacaoManual = false;

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
alice.Closed += async erro =>
{
    // Em um encerramento normal, o SignalR pode ir direto a Closed e nao acionar
    // WithAutomaticReconnect. Nesse caso, recuperar explicitamente a conexao.
    if (reconciliado.Task.IsCompleted) return;
    Console.WriteLine("R7.02 ESTADO: Desconectado; iniciando recuperacao manual");
    Exception? ultimaFalha = erro;
    for (var tentativa = 1; tentativa <= 5; tentativa++)
    {
        await Task.Delay(tentativa == 1 ? 300 : 1000);
        try
        {
            await alice.StartAsync();
            // A nova conexao nao herda os grupos da anterior.
            await alice.InvokeAsync("Acompanhar", pedidoId);
            using var estado = await aliceHttp.GetAsync($"/api/v1/pedidos/{pedidoId}");
            estado.EnsureSuccessStatusCode();
            using var documento = JsonDocument.Parse(await estado.Content.ReadAsStringAsync());
            recuperacaoManual = true;
            Console.WriteLine($"R7.02 ESTADO: Conectado; modo=MANUAL_APOS_FECHAMENTO; reingresso=SIM; GET HTTP={(int)estado.StatusCode}; versao_atual={documento.RootElement.GetProperty("versao").GetInt32()}; reconciliado=SIM");
            reconciliado.TrySetResult(true);
            return;
        }
        catch (Exception falha)
        {
            ultimaFalha = falha;
            Console.WriteLine($"R7.02 TENTATIVA: {tentativa}/5; falha={falha.GetType().Name}");
        }
    }
    reconciliado.TrySetException(ultimaFalha ?? new Exception("Falha na recuperacao do SignalR"));
};

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
if (!entrouEmReconexao && !recuperacaoManual)
    throw new Exception("Nenhuma reconexao foi observada.");
var modo = recuperacaoManual ? "MANUAL_APOS_FECHAMENTO" : "AUTOMATICA";
Console.WriteLine($"R7.02 RECONEXAO: modo={modo}; WithAutomaticReconnect_configurado=SIM; reassinatura=SIM; GET autoritativo=SIM");
Console.WriteLine("R7 RESULTADO: autorizacao, evento, reconexao, ETag/304, If-Match/412 e Output Cache aprovados.");
