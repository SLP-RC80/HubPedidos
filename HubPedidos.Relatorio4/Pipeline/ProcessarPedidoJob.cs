namespace HubPedidos.Relatorio4.Pipeline;

// Somente dados, sem DbContext ou entidade EF rastreada no canal.
public sealed record ProcessarPedidoJob(Guid PedidoId, DateTimeOffset? EnfileiradoEm = null);

public sealed record ConfiguracaoFila(int Capacidade, int Consumidores, int LimiteBanco, int AtrasoSimuladoMs = 50)
{
    public void Validar()
    {
        if (Capacidade <= 0 || Consumidores <= 0 || LimiteBanco <= 0 || AtrasoSimuladoMs < 0)
            throw new ArgumentOutOfRangeException(nameof(Capacidade), "Configuracao invalida.");
    }
}

public enum ResultadoEnfileiramento { Aceito, Duplicado, FilaCheia, Encerrado }
public enum EstadoPedido { EmFila, Processando, Concluido, Falhou }
