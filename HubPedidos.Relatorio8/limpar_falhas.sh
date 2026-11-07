#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
rm -f HubPedidos.IntegrationTests/ViolacaoTemporaria.cs HubPedidos.IntegrationTests/TesteFalhaTemporaria.cs
echo 'Arquivos de falha deliberada removidos. Compile e execute novamente para comprovar o gate verde.'
