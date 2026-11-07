#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspaces/HubPedidos
source HubPedidos.Relatorio7/.secrets/tokens.env
URL=http://localhost:5087
ID=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

printf '\n=== R7.03 GET AUTORIZADO / ETag ===\n'
code=$(curl -sS -D "$TMP/headers" -o "$TMP/body" -w '%{http_code}' -H "Authorization: Bearer $R7_ALICE_KEY" "$URL/api/v1/pedidos/$ID")
etag=$(grep -i '^ETag:' "$TMP/headers" | head -1 | cut -d' ' -f2- | tr -d '\r')
printf 'GET alice HTTP=%s; ETag presente=%s\n' "$code" "$([[ -n "$etag" ]] && echo SIM || echo NAO)"
cat "$TMP/body"; printf '\n'
printf '\n=== R7.03 IF-NONE-MATCH ===\n'
: > "$TMP/304"
code=$(curl -sS -o "$TMP/304" -w '%{http_code}' -H "Authorization: Bearer $R7_ALICE_KEY" -H "If-None-Match: $etag" "$URL/api/v1/pedidos/$ID")
printf 'GET condicional HTTP=%s; corpo_bytes=%s (esperado 304/0)\n' "$code" "$(wc -c < "$TMP/304")"
printf '\n=== R7.01 AUTORIZACAO ===\n'
sem_auth=$(curl -sS -o /dev/null -w '%{http_code}' "$URL/api/v1/pedidos/$ID")
printf 'GET sem credencial HTTP=%s (esperado 401)\n' "$sem_auth"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $R7_BOB_KEY" "$URL/api/v1/pedidos/$ID")
printf 'GET bob pedido da alice HTTP=%s (esperado 403)\n' "$code"
printf '\n=== R7.04 OUTPUT CACHE PUBLICO ===\n'
sp1=$(curl -fsS "$URL/api/publico/catalogo-status?regiao=SP")
sp2=$(curl -fsS "$URL/api/publico/catalogo-status?regiao=SP")
rj=$(curl -fsS "$URL/api/publico/catalogo-status?regiao=RJ")
[[ "$sp1" == "$sp2" ]] && echo 'SP repetido: cache HIT (mesmo JSON)' || echo 'SP repetido: resultados distintos, investigar cache'
[[ "$sp1" != "$rj" ]] && echo 'RJ: variacao por regiao confirmada' || echo 'RJ: resultado nao diferenciado'
printf 'SP: %s\nRJ: %s\n' "$sp1" "$rj"
