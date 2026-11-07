using System.Data.Common;
using Microsoft.EntityFrameworkCore.Diagnostics;

namespace HubPedidos.Infrastructure;

// Interceptor do EF: conta comandos efetivamente enviados, sem logar parâmetros sensíveis.
public sealed class ContadorComandos : DbCommandInterceptor
{
    private int _total;
    public int Total => Volatile.Read(ref _total);

    public override ValueTask<InterceptionResult<DbDataReader>> ReaderExecutingAsync(
        DbCommand command, CommandEventData eventData,
        InterceptionResult<DbDataReader> result, CancellationToken cancellationToken = default)
    {
        Interlocked.Increment(ref _total);
        return base.ReaderExecutingAsync(command, eventData, result, cancellationToken);
    }

    public override InterceptionResult<DbDataReader> ReaderExecuting(
        DbCommand command, CommandEventData eventData,
        InterceptionResult<DbDataReader> result)
    {
        Interlocked.Increment(ref _total);
        return base.ReaderExecuting(command, eventData, result);
    }
}
