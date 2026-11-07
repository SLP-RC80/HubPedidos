#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
p=HubPedidos.IntegrationTests/ViolacaoTemporaria.cs
[[ ! -e "$p" ]] || { echo "ERRO: $p ja existe." >&2; exit 1; }
cat > "$p" <<'CS'
using System;
namespace HubPedidos.IntegrationTests;
internal static class ViolacaoTemporaria
{
    public static void CausarViolacao()
    {
        try { throw new InvalidOperationException("demonstracao"); }
        catch (Exception ex) { throw ex; } // CA2200: rethrow que perde stack original.
    }
}
CS
printf 'R8.03: violacao CA2200 criada. Execute dotnet build HubPedidos.IntegrationTests -c Release.\n'
echo 'Depois da evidencia remova o arquivo via bash HubPedidos.Relatorio8/limpar_falhas.sh.'
