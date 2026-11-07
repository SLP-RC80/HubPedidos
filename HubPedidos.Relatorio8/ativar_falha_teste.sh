#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
p=HubPedidos.IntegrationTests/TesteFalhaTemporaria.cs
[[ ! -e "$p" ]] || { echo "ERRO: $p ja existe." >&2; exit 1; }
cat > "$p" <<'CS'
using Xunit;
namespace HubPedidos.IntegrationTests;
public sealed class TesteFalhaTemporaria
{
    [Fact]
    public void R8_Gate_Deve_Bloquear_Teste_Falho() => Assert.True(false, "Falha deliberada para a evidencia R8.04");
}
CS
printf 'R8.04: teste falho criado. Execute dotnet test HubPedidos.IntegrationTests -c Release.\n'
echo 'Para Actions, publique SOMENTE a branch experimental atividade-08-gate-falha, depois remova e reverta na branch principal.'
