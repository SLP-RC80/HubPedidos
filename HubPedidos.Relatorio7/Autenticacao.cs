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
