using System.Buffers;
using System.Text;
using HubPedidos.Application;
using Xunit;

namespace HubPedidos.Tests;

public sealed class ImportacaoLotesTests
{
    [Theory]
    [InlineData("1001;2;19.90;Mouse USB")]
    [InlineData("1002;1;7.50;Café ☕")]
    [InlineData("1003;10;120.00;Teclado")]
    [InlineData(" 1004;3;4.25;Caneta ")]
    public void Parsers_Sao_Equivalentes(string texto)
    {
        Assert.Equal(ParserLinhasPedido.Baseline(texto), ParserLinhasPedido.Otimizado(texto));
    }

    [Theory]
    [InlineData("")]
    [InlineData("1001;2;19.90")]
    [InlineData("1001;2;19.90;Mouse;EXTRA")]
    public void Parsers_Rejeitam_Linha_Vazia_Incompleta_Ou_Excessiva(string texto)
    {
        Assert.Throws<FormatException>(() => ParserLinhasPedido.Baseline(texto));
        Assert.Throws<FormatException>(() => ParserLinhasPedido.Otimizado(texto));
    }

    [Theory]
    [InlineData("1001;0;19.90;Mouse")]
    [InlineData("1001;2;0.00;Mouse")]
    public void Parsers_Rejeitam_Quantidade_Ou_Preco_Invalidos(string texto)
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ParserLinhasPedido.Baseline(texto));
        Assert.Throws<ArgumentOutOfRangeException>(() => ParserLinhasPedido.Otimizado(texto));
    }

    [Fact]
    public async Task Stream_UTF8_Multibyte_Em_Blocos_Pequenos_Funciona()
    {
        var lote = "1001;2;19.90;Café ☕\n1002;1;5.00;Pão de queijo\n";
        using var stream = Fonte(lote);
        var recebidos = new List<LinhaImportacao>();
        var quantidade = await new ImportadorLotes().ProcessarAsync(stream,
            (linha, _) => { recebidos.Add(linha); return ValueTask.CompletedTask; },
            tamanhoBloco: 3);

        Assert.Equal(2, quantidade);
        Assert.Equal("Café ☕", recebidos[0].Descricao);
        Assert.Equal("Pão de queijo", recebidos[1].Descricao);
    }

    [Fact]
    public async Task Stream_Sem_NovaLinha_Final_Eh_Processado()
    {
        using var stream = Fonte("1005;3;9.90;Caderno");
        var processados = await new ImportadorLotes().ProcessarAsync(stream,
            (_, _) => ValueTask.CompletedTask, tamanhoBloco: 5);
        Assert.Equal(1, processados);
    }

    [Fact]
    public async Task Stream_Vazio_Eh_Rejeitado()
    {
        using var stream = Fonte("");
        await Assert.ThrowsAsync<FormatException>(() =>
            new ImportadorLotes().ProcessarAsync(stream,
                (_, _) => ValueTask.CompletedTask, tamanhoBloco: 7));
    }

    [Fact]
    public async Task Stream_Acima_Do_Limite_Total_Eh_Rejeitado_E_Devolve_Buffers()
    {
        using var stream = Fonte("1001;2;19.90;Produto muito grande\n");
        var pool = new PoolRastreavel();
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            new ImportadorLotes(pool).ProcessarAsync(stream,
                (_, _) => ValueTask.CompletedTask,
                tamanhoBloco: 8, limiteTotalBytes: 12));
        Assert.Equal(2, pool.Devolvidos);
    }

    [Fact]
    public async Task Stream_Linha_Muito_Longa_Eh_Rejeitada_E_Devolve_Buffers()
    {
        using var stream = Fonte("1001;2;19.90;Descricao longa\n");
        var pool = new PoolRastreavel();
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            new ImportadorLotes(pool).ProcessarAsync(stream,
                (_, _) => ValueTask.CompletedTask,
                tamanhoBloco: 5, limiteLinhaBytes: 12));
        Assert.Equal(2, pool.Devolvidos);
    }

    [Fact]
    public async Task Stream_Cancelado_Devolve_Todos_Buffers()
    {
        using var stream = Fonte("1001;2;19.90;Mouse\n");
        var pool = new PoolRastreavel();
        using var cts = new CancellationTokenSource();
        cts.Cancel();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            new ImportadorLotes(pool).ProcessarAsync(stream,
                (_, _) => ValueTask.CompletedTask, tamanhoBloco: 8,
                cancellationToken: cts.Token));
        Assert.Equal(2, pool.Devolvidos);
    }

    [Fact]
    public async Task Stream_Falha_No_Consumidor_Devolve_Todos_Buffers()
    {
        using var stream = Fonte("1001;2;19.90;Mouse\n");
        var pool = new PoolRastreavel();
        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            new ImportadorLotes(pool).ProcessarAsync(stream,
                (_, _) => throw new InvalidOperationException("Falha simulada."),
                tamanhoBloco: 8));
        Assert.Equal(2, pool.Devolvidos);
    }

    [Fact]
    public async Task Stream_Grande_Respeita_Tamanho_Do_Buffer_De_Leitura()
    {
        var dados = string.Join('\n', Enumerable.Range(1, 4000)
            .Select(i => $"{i};2;19.90;Café")) + "\n";
        using var stream = new StreamMonitorado(Encoding.UTF8.GetBytes(dados));
        var vistos = 0;
        var total = await new ImportadorLotes().ProcessarAsync(stream,
            (_, _) => { vistos++; return ValueTask.CompletedTask; },
            tamanhoBloco: 32, limiteTotalBytes: 500_000);

        Assert.Equal(4000, total);
        Assert.Equal(4000, vistos);
        Assert.True(stream.MaiorLeituraSolicitada <= 32);
    }

    private static MemoryStream Fonte(string texto) =>
        new(Encoding.UTF8.GetBytes(texto));

    private sealed class PoolRastreavel : ArrayPool<byte>
    {
        public int Devolvidos { get; private set; }
        public override byte[] Rent(int minimumLength) => new byte[minimumLength];
        public override void Return(byte[] array, bool clearArray = false)
        {
            Devolvidos++;
            if (clearArray) Array.Clear(array);
        }
    }

    private sealed class StreamMonitorado(byte[] dados) : MemoryStream(dados)
    {
        public int MaiorLeituraSolicitada { get; private set; }
        public override ValueTask<int> ReadAsync(Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            MaiorLeituraSolicitada = Math.Max(MaiorLeituraSolicitada, buffer.Length);
            return base.ReadAsync(buffer, cancellationToken);
        }
    }
}
