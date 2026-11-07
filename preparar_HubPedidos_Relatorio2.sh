#!/usr/bin/env bash
set -euo pipefail

cd /workspaces/HubPedidos

echo '== Relatorio 2: verificacao de pre-requisitos =='
[[ "$(dotnet --version)" == 10.* ]] || { echo 'SDK .NET 10 e necessario'; exit 1; }
[[ -f HubPedidos.sln && -f HubPedidos.Application/HubPedidos.Application.csproj && -f HubPedidos.Tests/HubPedidos.Tests.csproj ]] || { echo 'ERRO: execute primeiro o Relatorio 1; solucao e projetos nao encontrados.'; exit 1; }
[[ "$(git branch --show-current)" == 'atividade-02-performance' ]] || { echo 'ERRO: crie e selecione a branch atividade-02-performance ANTES de executar este script.'; exit 1; }

# Nao sobrescreve nada ja criado.
for arquivo in \
  HubPedidos.Application/ImportacaoLotes.cs \
  HubPedidos.Tests/ImportacaoLotesTests.cs \
  HubPedidos.Benchmarks/HubPedidos.Benchmarks.csproj \
  HubPedidos.Benchmarks/Program.cs \
  HubPedidos.Benchmarks/ParserBenchmarks.cs; do
  if [[ -e "$arquivo" ]]; then
    echo "ERRO: arquivo existente encontrado: $arquivo. Nenhum conteudo foi sobrescrito."
    exit 1
  fi
done

mkdir -p evidencias/relatorio2

# Relatorios de benchmark podem ocupar bastante espaco; copiar apenas as evidencias finais.
if [[ -f .gitignore ]] && ! grep -q '^BenchmarkDotNet\.Artifacts/' .gitignore; then
  printf '\n# Artefatos temporarios de microbenchmark\nBenchmarkDotNet.Artifacts/\n' >> .gitignore
fi

echo '== Criando parser convencional, parser Span e importador de stream =='
cat > HubPedidos.Application/ImportacaoLotes.cs <<'CS'
using System.Buffers;
using System.Globalization;
using System.Text;

namespace HubPedidos.Application;

// Formato didatico: id;quantidade;preco;descricao (UTF-8, ponto decimal).
public sealed record LinhaImportacao(int Id, int Quantidade, decimal Preco, string Descricao);

public static class ParserLinhasPedido
{
    private const NumberStyles EstiloPreco =
        NumberStyles.AllowDecimalPoint | NumberStyles.AllowLeadingSign;

    public static LinhaImportacao Baseline(string linha)
    {
        ArgumentNullException.ThrowIfNull(linha);
        var partes = linha.Trim().Split(';');
        if (partes.Length != 4)
            throw new FormatException("Linha incompleta ou com campos adicionais.");

        var id = int.Parse(partes[0], NumberStyles.Integer, CultureInfo.InvariantCulture);
        var quantidade = int.Parse(partes[1], NumberStyles.Integer, CultureInfo.InvariantCulture);
        var preco = decimal.Parse(partes[2], EstiloPreco, CultureInfo.InvariantCulture);
        return CriarLinha(id, quantidade, preco, partes[3]);
    }

    public static LinhaImportacao Otimizado(ReadOnlySpan<char> linha)
    {
        linha = linha.Trim();
        var p1 = linha.IndexOf(';');
        if (p1 < 0) throw new FormatException("Campo id ausente.");

        var resto = linha[(p1 + 1)..];
        var segundoRelativo = resto.IndexOf(';');
        if (segundoRelativo < 0) throw new FormatException("Campo quantidade ausente.");

        var inicioPreco = p1 + segundoRelativo + 2;
        var partePrecoEDescricao = linha[inicioPreco..];
        var terceiroRelativo = partePrecoEDescricao.IndexOf(';');
        if (terceiroRelativo < 0)
            throw new FormatException("Campo preco ou descricao ausente.");

        var descricaoSpan = partePrecoEDescricao[(terceiroRelativo + 1)..];
        if (descricaoSpan.IndexOf(';') >= 0)
            throw new FormatException("Quantidade de campos invalida.");

        var id = int.Parse(linha[..p1], NumberStyles.Integer, CultureInfo.InvariantCulture);
        var quantidade = int.Parse(resto[..segundoRelativo], NumberStyles.Integer, CultureInfo.InvariantCulture);
        var preco = decimal.Parse(partePrecoEDescricao[..terceiroRelativo],
            EstiloPreco, CultureInfo.InvariantCulture);
        return CriarLinha(id, quantidade, preco, descricaoSpan.ToString());
    }

    private static LinhaImportacao CriarLinha(int id, int quantidade, decimal preco, string descricao)
    {
        if (id <= 0) throw new ArgumentOutOfRangeException(nameof(id), "ID deve ser positivo.");
        if (quantidade <= 0) throw new ArgumentOutOfRangeException(nameof(quantidade), "Quantidade deve ser positiva.");
        if (preco <= 0m) throw new ArgumentOutOfRangeException(nameof(preco), "Preco deve ser positivo.");
        if (string.IsNullOrWhiteSpace(descricao))
            throw new ArgumentException("Descricao obrigatoria.");

        return new LinhaImportacao(id, quantidade, preco, descricao.Trim());
    }
}

/// <summary>
/// Le fluxo UTF-8 sem carregar o lote inteiro. Acumula apenas uma linha,
/// preservando bytes multibyte que atravessem blocos de leitura.
/// </summary>
public sealed class ImportadorLotes(ArrayPool<byte>? pool = null)
{
    private readonly ArrayPool<byte> _pool = pool ?? ArrayPool<byte>.Shared;
    private static readonly UTF8Encoding Utf8Estrito = new(false, true);

    public async Task<int> ProcessarAsync(
        Stream origem,
        Func<LinhaImportacao, CancellationToken, ValueTask> consumir,
        int tamanhoBloco = 4096,
        long limiteTotalBytes = 1_048_576,
        int limiteLinhaBytes = 1024,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(origem);
        ArgumentNullException.ThrowIfNull(consumir);
        if (!origem.CanRead) throw new ArgumentException("Stream precisa permitir leitura.");
        if (tamanhoBloco <= 0 || limiteTotalBytes <= 0 || limiteLinhaBytes <= 0)
            throw new ArgumentOutOfRangeException(nameof(tamanhoBloco), "Limites devem ser positivos.");

        var leitura = _pool.Rent(tamanhoBloco);
        byte[]? linha = null;
        try
        {
            linha = _pool.Rent(limiteLinhaBytes);
            int usados = 0;
            int processados = 0;
            long bytesTotais = 0;

            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                // Memory<byte> pode participar de await; Span e tratado apenas em metodo sincrono.
                var lidos = await origem.ReadAsync(leitura.AsMemory(0, tamanhoBloco), cancellationToken);
                if (lidos == 0) break;

                bytesTotais += lidos;
                if (bytesTotais > limiteTotalBytes)
                    throw new InvalidDataException("Lote excedeu o limite total de bytes.");

                var concluidas = new List<LinhaImportacao>();
                ConsumirBloco(leitura, lidos, linha, ref usados, limiteLinhaBytes, concluidas);
                foreach (var registro in concluidas)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    await consumir(registro, cancellationToken);
                    processados++;
                }
            }

            if (usados > 0)
            {
                var registro = ConverterLinha(linha.AsSpan(0, usados));
                cancellationToken.ThrowIfCancellationRequested();
                await consumir(registro, cancellationToken);
                processados++;
            }

            if (processados == 0)
                throw new FormatException("Lote vazio.");

            return processados;
        }
        finally
        {
            // Devolver exatamente uma vez, inclusive ao cancelar ou lancar excecao.
            if (linha is not null) _pool.Return(linha, clearArray: true);
            _pool.Return(leitura, clearArray: true);
        }
    }

    private static void ConsumirBloco(
        byte[] leitura, int lidos, byte[] linha, ref int usados,
        int limiteLinhaBytes, List<LinhaImportacao> concluidas)
    {
        var dados = leitura.AsSpan(0, lidos);
        while (!dados.IsEmpty)
        {
            var fim = dados.IndexOf((byte)'\n');
            if (fim < 0)
            {
                CopiarSegmento(dados, linha, ref usados, limiteLinhaBytes);
                return;
            }

            CopiarSegmento(dados[..fim], linha, ref usados, limiteLinhaBytes);
            concluidas.Add(ConverterLinha(linha.AsSpan(0, usados)));
            usados = 0;
            dados = dados[(fim + 1)..];
        }
    }

    private static void CopiarSegmento(ReadOnlySpan<byte> segmento, byte[] linha,
        ref int usados, int limiteLinhaBytes)
    {
        if (segmento.Length > limiteLinhaBytes - usados)
            throw new InvalidDataException("Linha excedeu o limite permitido.");
        segmento.CopyTo(linha.AsSpan(usados));
        usados += segmento.Length;
    }

    private static LinhaImportacao ConverterLinha(ReadOnlySpan<byte> bytes)
    {
        if (!bytes.IsEmpty && bytes[^1] == (byte)'\r') bytes = bytes[..^1];
        // Converte somente a linha completa: caracteres UTF-8 repartidos entre blocos
        // permanecem intactos no buffer ate o decodificador receber todos os bytes.
        var texto = Utf8Estrito.GetString(bytes);
        return ParserLinhasPedido.Otimizado(texto.AsSpan());
    }
}
CS

echo '== Criando testes de equivalencia, UTF-8, limites e devolucao de buffers =='
cat > HubPedidos.Tests/ImportacaoLotesTests.cs <<'CS'
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
CS

echo '== Criando projeto BenchmarkDotNet (somente esta unidade) =='
dotnet new console -n HubPedidos.Benchmarks -f net10.0 --no-restore
dotnet sln HubPedidos.sln add HubPedidos.Benchmarks/HubPedidos.Benchmarks.csproj
dotnet add HubPedidos.Benchmarks/HubPedidos.Benchmarks.csproj reference HubPedidos.Application/HubPedidos.Application.csproj
dotnet add HubPedidos.Benchmarks/HubPedidos.Benchmarks.csproj package BenchmarkDotNet

cat > HubPedidos.Benchmarks/Program.cs <<'CS'
using BenchmarkDotNet.Running;

BenchmarkSwitcher.FromAssembly(typeof(Program).Assembly).Run(args);
CS

cat > HubPedidos.Benchmarks/ParserBenchmarks.cs <<'CS'
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
CS

echo '== Restaurando, compilando e testando todas as unidades existentes =='
dotnet restore HubPedidos.sln
dotnet build HubPedidos.sln -c Release --no-restore
dotnet test HubPedidos.Tests/HubPedidos.Tests.csproj -c Release --no-build --logger 'console;verbosity=normal'

echo
printf '%s\n' 'PREPARACAO DO RELATORIO 2 CONCLUIDA.' 'Proximos comandos:' \
  "  dotnet test HubPedidos.Tests/HubPedidos.Tests.csproj -c Release --filter 'FullyQualifiedName~ImportacaoLotesTests' --logger 'console;verbosity=normal'" \
  "  dotnet run --project HubPedidos.Benchmarks -c Release -- --filter '*ParserBenchmarks*' --job short" \
  "  dotnet run --project HubPedidos.Benchmarks -c Release -- --filter '*BufferBenchmarks*' --job short"
