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
