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
