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
