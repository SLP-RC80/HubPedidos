#!/usr/bin/env bash
set -euo pipefail
BASE="${1:-http://localhost:5086}"
ID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
printf '\n=== R6.03 V1 ===\n'
curl -sS -i "$BASE/api/v1/pedidos/$ID"
printf '\n\n=== R6.03 V2 ===\n'
curl -sS -i "$BASE/api/v2/pedidos/$ID"
printf '\n\n=== R6.03 SEM VERSAO ===\n'
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "$BASE/api/pedidos/$ID"
printf '\n=== R6.03 VERSAO DESCONHECIDA ===\n'
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' "$BASE/api/v3/pedidos/$ID"
printf '\n=== R6.03 OPENAPI - ROTAS ===\n'
curl -fsS "$BASE/openapi/v1.json" | python3 -c 'import json,sys; doc=json.load(sys.stdin); print("OpenAPI",doc.get("openapi")); print("\n".join(sorted(doc.get("paths",{}))))'
printf '\n=== R6.04 TELEMETRIA V1 ===\n'
curl -sS "$BASE/api/metricas/versoes"; printf '\n'
