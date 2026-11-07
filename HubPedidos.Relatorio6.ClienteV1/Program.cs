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
