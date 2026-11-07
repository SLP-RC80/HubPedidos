#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
export R7_CREDENTIALS_FILE="$PWD/HubPedidos.Relatorio7/.secrets/tokens.env"
dotnet run --project HubPedidos.Relatorio7.Cliente/HubPedidos.Relatorio7.Cliente.csproj \
  -c Release --no-launch-profile -- http://localhost:5087
