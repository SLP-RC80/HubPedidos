using System.Text;
using BenchmarkDotNet.Attributes;
using HubPedidos.Application;

namespace HubPedidos.Benchmarks;

[MemoryDiagnoser]
public class ParserBenchmarks
{
    [Params(50, 1000)]
    public int QuantidadeLinhas { get; set; }

    private string[] _linhas = [];

    [GlobalSetup]
    public void Preparar()
    {
        _linhas = Enumerable.Range(1, QuantidadeLinhas)
            .Select(i => $"{i};2;19.90;Produto {i}")
            .ToArray();
    }

    [Benchmark(Baseline = true)]
    public decimal BaselineSplit()
    {
        decimal soma = 0;
        foreach (var linha in _linhas)
            soma += ParserLinhasPedido.Baseline(linha).Preco;
        return soma;
    }

    [Benchmark]
    public decimal OtimizadoSpan()
    {
        decimal soma = 0;
        foreach (var linha in _linhas)
            soma += ParserLinhasPedido.Otimizado(linha.AsSpan()).Preco;
        return soma;
    }
}

// Extensao de aprimoramento: comparar dois tamanhos do buffer, sem mudar contrato.
[MemoryDiagnoser]
public class BufferBenchmarks
{
    [Params(200, 2000)]
    public int QuantidadeLinhas { get; set; }

    private byte[] _dados = [];

    [GlobalSetup]
    public void Preparar()
    {
        var texto = string.Join('\n', Enumerable.Range(1, QuantidadeLinhas)
            .Select(i => $"{i};2;19.90;Café")) + "\n";
        _dados = Encoding.UTF8.GetBytes(texto);
    }

    [Benchmark(Baseline = true)]
    public Task<int> Buffer256() => Importar(256);

    [Benchmark]
    public Task<int> Buffer8192() => Importar(8192);

    private async Task<int> Importar(int tamanhoBloco)
    {
        using var stream = new MemoryStream(_dados, writable: false);
        return await new ImportadorLotes().ProcessarAsync(stream,
            (_, _) => ValueTask.CompletedTask,
            tamanhoBloco: tamanhoBloco, limiteTotalBytes: 500_000);
    }
}
