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
