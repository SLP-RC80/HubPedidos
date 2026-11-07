#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
export R7_CREDENTIALS_FILE="$PWD/HubPedidos.Relatorio7/.secrets/tokens.env"
export R7_DATABASE_FILE="$PWD/HubPedidos.Relatorio7/.data/pedidos.db"
export ASPNETCORE_ENVIRONMENT=Development
export ASPNETCORE_URLS=http://0.0.0.0:5087
dotnet run --project HubPedidos.Relatorio7/HubPedidos.Relatorio7.csproj -c Release --no-launch-profile
