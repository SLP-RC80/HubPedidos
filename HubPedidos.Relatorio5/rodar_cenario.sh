#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
CENARIO="${1:-}"
[[ "$CENARIO" == 'antes' || "$CENARIO" == 'depois' || "$CENARIO" == 'degraus' ]] || { echo 'Uso: bash HubPedidos.Relatorio5/rodar_cenario.sh antes|depois|degraus'; exit 2; }
[[ -f HubPedidos.Relatorio4/bin/Release/net10.0/HubPedidos.Relatorio4.dll ]] || { echo 'Primeiro execute: dotnet build -c Release'; exit 2; }
export PATH="$PATH:$HOME/.dotnet/tools"
for command in python3 curl dotnet-counters dotnet-trace; do
  command -v "$command" >/dev/null || { echo "Ferramenta ausente: $command"; exit 2; }
done
OUT="$ROOT/HubPedidos.Relatorio5/evidencias"
PORT=5085
URL="http://127.0.0.1:$PORT"
if curl -sf --max-time 1 "$URL/api/pipeline/metricas" >/dev/null 2>&1; then
  echo "A porta $PORT ja tem uma API respondendo; encerre a API antes de iniciar o teste."; exit 2
fi
LIMITE=1
[[ "$CENARIO" != 'antes' ]] && LIMITE=2
printf '\n=== R5.04: CENARIO %s / limite_banco=%s ===\n' "$CENARIO" "$LIMITE"
API_PID='' COUNTERS_PID='' TRACE_PID=''
cleanup() {
  set +e
  if [[ -n "$COUNTERS_PID" ]] && kill -0 "$COUNTERS_PID" 2>/dev/null; then
    kill -INT "$COUNTERS_PID" 2>/dev/null
    sleep 2
    kill -TERM "$COUNTERS_PID" 2>/dev/null
    wait "$COUNTERS_PID" 2>/dev/null
  fi
  if [[ -n "$TRACE_PID" ]] && kill -0 "$TRACE_PID" 2>/dev/null; then
    kill -TERM "$TRACE_PID" 2>/dev/null
    wait "$TRACE_PID" 2>/dev/null
  fi
  if [[ -n "$API_PID" ]] && kill -0 "$API_PID" 2>/dev/null; then
    kill -TERM "$API_PID" 2>/dev/null
    wait "$API_PID" 2>/dev/null
  fi
}
trap cleanup EXIT
ASPNETCORE_URLS="$URL" \
 R4_CAPACIDADE=40 R4_CONSUMIDORES=4 R4_LIMITE_BANCO="$LIMITE" R4_ATRASO_MS=60 \
 DOTNET_ENVIRONMENT=Production \
 dotnet HubPedidos.Relatorio4/bin/Release/net10.0/HubPedidos.Relatorio4.dll \
 >"$OUT/$CENARIO-api.log" 2>&1 &
API_PID=$!
ready=0
for i in $(seq 1 50); do
  if curl -sf --max-time 1 "$URL/api/pipeline/metricas" >/dev/null 2>&1; then ready=1; break; fi
  if ! kill -0 "$API_PID" 2>/dev/null; then break; fi
  sleep 0.2
done
[[ "$ready" -eq 1 ]] || { echo 'ERRO: API nao iniciou. Verifique o log:'; tail -n 30 "$OUT/$CENARIO-api.log"; exit 3; }
printf 'R5.01 API PID=%s, porta=%s, consumidores=4, capacidade=40, limite=%s, atraso=60ms\n' "$API_PID" "$PORT" "$LIMITE"

# Captura de contadores durante aquecimento e medicao, salva em CSV.
dotnet-counters collect --process-id "$API_PID" --refresh-interval 1 --counters System.Runtime \
 --format csv --output "$OUT/$CENARIO-counters" >"$OUT/$CENARIO-counters.log" 2>&1 &
COUNTERS_PID=$!
# Trace de 15 s, inclui aquecimento e parte da carga medida.
dotnet-trace collect --process-id "$API_PID" --duration 00:00:00:15 \
 --output "$OUT/$CENARIO-trace.nettrace" >"$OUT/$CENARIO-trace.log" 2>&1 &
TRACE_PID=$!
sleep 2
if [[ "$CENARIO" == 'degraus' ]]; then
  python3 HubPedidos.Relatorio5/degraus.py --url "$URL" --out "$OUT"
else
  python3 HubPedidos.Relatorio5/carga.py --url "$URL" --nome "$CENARIO" \
    --rate 30 --warmup 5 --seconds 20 --out "$OUT"
fi

# Aguardar trace finalizar para gerar arquivo analisavel.
set +e
wait "$TRACE_PID"; trace_status=$?
TRACE_PID=''
set -e
if [[ "$trace_status" -ne 0 || ! -s "$OUT/$CENARIO-trace.nettrace" ]]; then
  echo 'AVISO: trace nao foi gerado; confira o log e repita a coleta para R5.03.'
  tail -n 10 "$OUT/$CENARIO-trace.log" || true
else
  if dotnet-trace convert "$OUT/$CENARIO-trace.nettrace" --format Speedscope \
    -o "$OUT/$CENARIO-speedscope" >"$OUT/$CENARIO-convert.log" 2>&1; then
    echo "R5.03 Trace exportado para Speedscope. Procure em: $OUT"
  else
    echo 'AVISO: falha na conversao Speedscope; trace .nettrace preservado.'
  fi
fi
# Sinaliza Ctrl+C para concluir o CSV do dotnet-counters.
kill -INT "$COUNTERS_PID" 2>/dev/null || true
sleep 2
if kill -0 "$COUNTERS_PID" 2>/dev/null; then kill -TERM "$COUNTERS_PID" 2>/dev/null || true; fi
set +e
wait "$COUNTERS_PID" 2>/dev/null
set -e
COUNTERS_PID=''
if [[ -s "$OUT/$CENARIO-counters.csv" ]]; then
  printf 'R5.02 Counters salvos: %s\n' "$OUT/$CENARIO-counters.csv"
else
  echo 'AVISO: counters CSV vazio/ausente; confira o log de coleta.'
  tail -n 12 "$OUT/$CENARIO-counters.log" || true
fi
printf 'R5.04 Cenario %s concluido. Arquivos no diretorio: %s\n' "$CENARIO" "$OUT"
