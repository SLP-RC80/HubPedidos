#!/usr/bin/env bash
set -euo pipefail

cd /workspaces/HubPedidos

echo '== Verificando .NET SDK =='
SDK_VERSION="$(dotnet --version)"
if [[ "$SDK_VERSION" != 10.* ]]; then
  echo "ERRO: a solução exige SDK .NET 10 (encontrado: $SDK_VERSION)."
  echo 'Execute dotnet --list-sdks e ajuste o devcontainer antes de continuar.'
  exit 1
fi

if [[ -e HubPedidos.sln || -e HubPedidos.slnx || -e HubPedidos.Api || -e HubPedidos.Domain || -e HubPedidos.Application || -e HubPedidos.Tests ]]; then
  echo 'ERRO: projetos ou solução já encontrados. Não sobrescrevi arquivos.'
  echo 'Confira ls -la e a estrutura atual antes de executar este script.'
  exit 1
fi

echo '== Criando solução e projetos .NET 10 =='
dotnet new sln -n HubPedidos --format sln
dotnet new web -n HubPedidos.Api -f net10.0
dotnet new classlib -n HubPedidos.Domain -f net10.0
dotnet new classlib -n HubPedidos.Application -f net10.0
dotnet new xunit -n HubPedidos.Tests -f net10.0

dotnet sln HubPedidos.sln add \
  HubPedidos.Api/HubPedidos.Api.csproj \
  HubPedidos.Domain/HubPedidos.Domain.csproj \
  HubPedidos.Application/HubPedidos.Application.csproj \
  HubPedidos.Tests/HubPedidos.Tests.csproj

dotnet add HubPedidos.Application/HubPedidos.Application.csproj reference HubPedidos.Domain/HubPedidos.Domain.csproj
dotnet add HubPedidos.Api/HubPedidos.Api.csproj reference HubPedidos.Application/HubPedidos.Application.csproj
dotnet add HubPedidos.Tests/HubPedidos.Tests.csproj reference HubPedidos.Domain/HubPedidos.Domain.csproj HubPedidos.Application/HubPedidos.Application.csproj

rm -f HubPedidos.Domain/Class1.cs HubPedidos.Application/Class1.cs HubPedidos.Tests/UnitTest1.cs
mkdir -p evidencias/relatorio1

cat > HubPedidos.Domain/Pedido.cs <<'CS'
namespace HubPedidos.Domain;

public readonly record struct PedidoId(Guid Valor)
{
    public static PedidoId Criar(Guid valor)
    {
        if (valor == Guid.Empty)
            throw new ArgumentException("Identificador do pedido inválido.");
        return new PedidoId(valor);
    }
}

public sealed record ItemPedido
{
    public string Produto { get; }
    public int Quantidade { get; }
    public decimal PrecoUnitario { get; }

    public ItemPedido(string produto, int quantidade, decimal precoUnitario)
    {
        if (string.IsNullOrWhiteSpace(produto))
            throw new ArgumentException("Produto obrigatório.");
        if (quantidade <= 0)
            throw new ArgumentOutOfRangeException(nameof(quantidade), "Quantidade deve ser positiva.");
        if (precoUnitario <= 0)
            throw new ArgumentOutOfRangeException(nameof(precoUnitario), "Preço deve ser positivo.");

        Produto = produto.Trim();
        Quantidade = quantidade;
        PrecoUnitario = precoUnitario;
    }
}

public sealed class Pedido
{
    public PedidoId Id { get; }
    public string Regiao { get; }
    public bool Prioritario { get; }
    public IReadOnlyList<ItemPedido> Itens { get; }
    public decimal Total => Itens.Sum(i => i.Quantidade * i.PrecoUnitario);

    public Pedido(PedidoId id, string regiao, bool prioritario, IEnumerable<ItemPedido> itens)
    {
        if (id.Valor == Guid.Empty)
            throw new ArgumentException("Identificador do pedido inválido.");
        if (string.IsNullOrWhiteSpace(regiao))
            throw new ArgumentException("Região obrigatória.");
        if (itens is null)
            throw new ArgumentException("Itens obrigatórios.");

        var copia = itens.ToArray();
        if (copia.Length == 0 || copia.Any(i => i is null))
            throw new ArgumentException("Pedido precisa de itens válidos.");

        Id = id;
        Regiao = regiao.Trim();
        Prioritario = prioritario;
        Itens = Array.AsReadOnly(copia); // cópia própria, não expõe coleção mutável
    }
}
CS

cat > HubPedidos.Application/PedidosApp.cs <<'CS'
using System.Reflection;
using HubPedidos.Domain;

namespace HubPedidos.Application;

public sealed record ItemPedidoRequest(string Produto, int Quantidade, decimal PrecoUnitario);
public sealed record CriarPedidoRequest(
    Guid Id, string Regiao, bool Prioritario, IReadOnlyList<ItemPedidoRequest>? Itens);
public sealed record PedidoResponse(Guid Id, string Categoria, decimal Total, string Resultado);

public static class PedidoMapper
{
    public static Pedido ParaDominio(CriarPedidoRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);
        if (request.Itens is null || request.Itens.Count == 0)
            throw new ArgumentException("O pedido precisa de itens.");

        var itens = request.Itens
            .Select(x => x is null
                ? throw new ArgumentException("Item inválido.")
                : new ItemPedido(x.Produto, x.Quantidade, x.PrecoUnitario))
            .ToArray();

        return new Pedido(PedidoId.Criar(request.Id), request.Regiao,
            request.Prioritario, itens);
    }
}

public static class ClassificadorPedido
{
    public static string Classificar(Pedido? pedido) => pedido switch
    {
        null => "invalido",
        { Total: <= 0m } => "invalido",
        { Prioritario: true } => "prioritario",
        { Total: >= 1000m, Itens.Count: >= 3 } => "prioritario",
        { Regiao: "Norte" } => "prioritario",
        _ => "normal"
    };
}

[AttributeUsage(AttributeTargets.Class, AllowMultiple = false, Inherited = false)]
public sealed class ProcessadorPedidoAttribute : Attribute
{
    public string Categoria { get; }
    public int Versao { get; }

    public ProcessadorPedidoAttribute(string categoria, int versao)
    {
        Categoria = categoria;
        Versao = versao;
    }
}

public interface IProcessadorPedido
{
    string Executar(Pedido pedido);
}

[ProcessadorPedido("normal", 1)]
public sealed class ProcessadorNormal : IProcessadorPedido
{
    public string Executar(Pedido pedido) => "Fluxo normal selecionado.";
}

[ProcessadorPedido("prioritario", 1)]
public sealed class ProcessadorPrioritario : IProcessadorPedido
{
    public string Executar(Pedido pedido) => "Fluxo prioritário selecionado.";
}

public sealed class CatalogoProcessadores
{
    private readonly Dictionary<(string Categoria, int Versao), IProcessadorPedido> _processadores = new();

    public CatalogoProcessadores(Assembly assembly)
    {
        foreach (var tipo in assembly.GetTypes()
            .Where(t => t.IsClass && !t.IsAbstract &&
                typeof(IProcessadorPedido).IsAssignableFrom(t))
            .OrderBy(t => t.Name, StringComparer.Ordinal))
        {
            var meta = tipo.GetCustomAttribute<ProcessadorPedidoAttribute>();
            if (meta is null) continue;
            if (tipo.GetConstructor(Type.EmptyTypes) is null)
                throw new InvalidOperationException($"Construtor inválido em {tipo.Name}.");

            var chave = (meta.Categoria, meta.Versao);
            if (!_processadores.TryAdd(chave, (IProcessadorPedido)Activator.CreateInstance(tipo)!))
                throw new InvalidOperationException($"Processador duplicado: {chave}.");
        }

        if (_processadores.Count == 0)
            throw new InvalidOperationException("Nenhum processador registrado.");
    }

    public IProcessadorPedido Obter(string categoria, int versao = 1) =>
        _processadores.TryGetValue((categoria, versao), out var p)
            ? p
            : throw new KeyNotFoundException($"Processador ausente: {categoria}, v{versao}.");
}
CS

cat > HubPedidos.Api/Program.cs <<'CS'
using HubPedidos.Application;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddSingleton(_ =>
    new CatalogoProcessadores(typeof(ProcessadorNormal).Assembly));

var app = builder.Build();
// Força a validação do catálogo uma única vez na inicialização.
_ = app.Services.GetRequiredService<CatalogoProcessadores>();

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapPost("/api/pedidos/classificar", (
    CriarPedidoRequest request, CatalogoProcessadores catalogo) =>
{
    try
    {
        var pedido = PedidoMapper.ParaDominio(request);
        var categoria = ClassificadorPedido.Classificar(pedido);
        var processador = catalogo.Obter(categoria);
        var resposta = new PedidoResponse(
            pedido.Id.Valor, categoria, pedido.Total, processador.Executar(pedido));
        return Results.Ok(resposta);
    }
    catch (ArgumentException ex)
    {
        return Results.BadRequest(new { erro = ex.Message });
    }
});

app.Run();
public partial class Program { } // prepara WebApplicationFactory do roteiro 8
CS

cat > HubPedidos.Tests/PedidosTests.cs <<'CS'
using HubPedidos.Application;
using HubPedidos.Domain;
using Xunit;

namespace HubPedidos.Tests;

public sealed class PedidosTests
{
    private static Pedido Montar(bool prioritario, string regiao, int unitario, int quantos)
    {
        var itens = Enumerable.Range(1, quantos)
            .Select(i => new ItemPedido($"Produto {i}", 1, unitario))
            .ToList();
        return new Pedido(PedidoId.Criar(Guid.NewGuid()), regiao, prioritario, itens);
    }

    [Theory]
    [InlineData(false, "Sul", 100, 1, "normal")]
    [InlineData(true, "Sul", 100, 1, "prioritario")]
    [InlineData(false, "Norte", 100, 1, "prioritario")]
    [InlineData(false, "Sul", 400, 3, "prioritario")]
    [InlineData(false, "Sul", 400, 2, "normal")]
    public void Classificacao_Possui_Casos_Equivalentes(
        bool prioritario, string regiao, int valorUnitario, int totalItens, string esperado)
    {
        var pedido = Montar(prioritario, regiao, valorUnitario, totalItens);
        Assert.Equal(esperado, ClassificadorPedido.Classificar(pedido));
    }

    [Fact]
    public void Classificacao_CasoLimite_ExatamenteMil()
    {
        var itens = new[]
        {
            new ItemPedido("A", 1, 300m),
            new ItemPedido("B", 1, 300m),
            new ItemPedido("C", 1, 400m)
        };
        var pedido = new Pedido(PedidoId.Criar(Guid.NewGuid()), "Sul", false, itens);
        Assert.Equal("prioritario", ClassificadorPedido.Classificar(pedido));
    }

    [Fact]
    public void Classificacao_Nula_Eh_Invalida() =>
        Assert.Equal("invalido", ClassificadorPedido.Classificar(null));

    [Fact]
    public void Dto_Invalido_Eh_Rejeitado_Antes_Do_Dominio()
    {
        var dto = new CriarPedidoRequest(Guid.NewGuid(), "Sul", false,
            new[] { new ItemPedidoRequest("Caneta", 0, 10m) });
        Assert.Throws<ArgumentOutOfRangeException>(() => PedidoMapper.ParaDominio(dto));
        Assert.Throws<ArgumentException>(() => PedidoId.Criar(Guid.Empty));
    }

    [Fact]
    public void Records_Com_Os_Mesmos_Valores_Sao_Iguais()
    {
        var primeiro = new ItemPedidoRequest("Caneta", 1, 10m);
        var segundo = new ItemPedidoRequest("Caneta", 1, 10m);
        Assert.Equal(primeiro, segundo);
    }

    [Fact]
    public void Record_With_Preserva_Original()
    {
        var original = new ItemPedidoRequest("Caneta", 1, 10m);
        var copia = original with { Quantidade = 2 };
        Assert.Equal(1, original.Quantidade);
        Assert.Equal(2, copia.Quantidade);
    }

    [Fact]
    public void Itens_Sao_Copiados_E_Nao_Podem_Ser_Modificados()
    {
        var lista = new List<ItemPedido> { new("Caneta", 1, 10m) };
        var pedido = new Pedido(PedidoId.Criar(Guid.NewGuid()), "Sul", false, lista);
        lista.Clear();
        Assert.Single(pedido.Itens);
        Assert.Throws<NotSupportedException>(() =>
            ((IList<ItemPedido>)pedido.Itens).Clear());
    }

    [Fact]
    public void Catalogo_Descobre_Apenas_Assembly_Conhecido()
    {
        var catalogo = new CatalogoProcessadores(typeof(ProcessadorNormal).Assembly);
        Assert.NotNull(catalogo.Obter("normal"));
        Assert.NotNull(catalogo.Obter("prioritario"));
    }

    [Fact]
    public void Catalogo_Rejeita_Duplicados()
    {
        Assert.Throws<InvalidOperationException>(() =>
            new CatalogoProcessadores(typeof(PrimeiroDuplicado).Assembly));
    }
}

[ProcessadorPedido("duplicado", 1)]
public sealed class PrimeiroDuplicado : IProcessadorPedido
{
    public string Executar(Pedido pedido) => "A";
}

[ProcessadorPedido("duplicado", 1)]
public sealed class SegundoDuplicado : IProcessadorPedido
{
    public string Executar(Pedido pedido) => "B";
}
CS

echo '== Restaurando, compilando e executando os testes =='
dotnet restore HubPedidos.sln
dotnet build HubPedidos.sln -c Release --no-restore
dotnet test HubPedidos.sln -c Release --no-build

echo '== Concluído: R1 pronto para revisão, execução HTTP e evidências =='
echo 'API: ASPNETCORE_URLS=http://0.0.0.0:5080 dotnet run --project HubPedidos.Api -c Release'
