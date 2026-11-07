#!/usr/bin/env bash
set -euo pipefail
ROOT=/workspaces/HubPedidos
cd "$ROOT"

printf '\n=== RELATORIO 5: PRE-CHECAGEM ===\n'
[[ "$(dotnet --version)" == 10.* ]] || { echo 'ERRO: SDK .NET 10 obrigatorio.'; exit 1; }
[[ "$(git branch --show-current)" == 'atividade-05-diagnostico' ]] || { echo 'ERRO: selecione a branch atividade-05-diagnostico.'; exit 1; }
[[ -f HubPedidos.Relatorio4/HubPedidos.Relatorio4.csproj && -f HubPedidos.Benchmarks/HubPedidos.Benchmarks.csproj ]] || { echo 'ERRO: projetos R2/R4 nao encontrados.'; exit 1; }
command -v python3 >/dev/null || { echo 'ERRO: python3 indisponivel.'; exit 1; }
command -v curl >/dev/null || { echo 'ERRO: curl indisponivel.'; exit 1; }
export PATH="$PATH:$HOME/.dotnet/tools"
command -v dotnet-counters >/dev/null || { echo 'ERRO: instale dotnet-counters (dotnet tool install --global dotnet-counters).'; exit 1; }
command -v dotnet-trace >/dev/null || { echo 'ERRO: instale dotnet-trace (dotnet tool install --global dotnet-trace).'; exit 1; }
if [[ -e HubPedidos.Relatorio5 ]]; then
  echo 'ERRO: HubPedidos.Relatorio5 ja existe. O script nao altera arquivos existentes.'; exit 1
fi
mkdir -p HubPedidos.Relatorio5/evidencias

cat > HubPedidos.Relatorio5/plano.md <<'MD'
# R5.01 – Plano de medição: diagnóstico e perfilamento

## Hipótese
O limite de **uma operação simultânea** na persistência simulada forma uma fila de espera sob taxa de entrada superior à capacidade de consumo. A alteração **exclusiva do limite de operações simultâneas de 1 para 2** deve reduzir o número de rejeições HTTP 429 e ampliar os pedidos concluídos durante a janela, embora a latência de cada requisição HTTP possa não melhorar.

## Rotas e método isolável
- Criação: `POST /api/pipeline/enfileirar`, retorno `202` quando aceita; `429` quando cheia.
- Consulta: `GET /api/pipeline/status/{id}`, retorno `200` para o pedido criado no início da rodada.
- Métrica do canal: `GET /api/pipeline/metricas` (fila, pico, espera, processamento e rejeições).
- Método isolável: `ParserLinhasPedido.Baseline` versus `ParserLinhasPedido.Otimizado`, projeto `HubPedidos.Benchmarks`, já implementado no Relatório 2; **novo benchmark** executado para o R5.

## Cenário controlado (antes/depois)
- Base de código: mesma versão do HubPedidos.Relatorio4.
- `R4_CAPACIDADE=40`, `R4_CONSUMIDORES=4`, `R4_ATRASO_MS=60` (mesmos valores em ambas as rodadas).
- Intervenção única: `R4_LIMITE_BANCO=1` (antes) versus `R4_LIMITE_BANCO=2` (depois).
- Persistência **simulada** em memória, sem acesso ao Neon durante esta carga. A integração PostgreSQL foi verificada separadamente no R4.03.
- Carga: 30 requisições HTTP/s planejadas, 75% POST e 25% GET, 24 trabalhadores de cliente; 5 s de aquecimento a 8 req/s, descartados do cálculo, e 20 s de medição.
- Corpo POST: UUID único por requisição. GET consulta UUID válido criado antes do aquecimento.
- Nova instância da API para cada rodada, para zerar métricas e estado.
- Ferramentas: BenchmarkDotNet (Release), `dotnet-counters collect` (CSV), `dotnet-trace collect` (.nettrace / Speedscope), Python 3 (cliente HTTP stdlib e cálculo de percentis), xUnit.

## Metas didáticas predefinidas (não são resultados)
- p95 HTTP <= 150 ms, p99 HTTP <= 300 ms.
- Vazão de pedidos **aceitos** >= 20 pedidos/s durante a janela medida.
- Taxa de respostas HTTP não bem-sucedidas (incluindo 429) <= 5%.
- Sem timeout e sem HTTP 5xx; invariantes da fila preservadas; suíte de testes sem regressão.

## Métricas e limitações
- p50/p95/p99 são calculados sobre **durações individuais das requisições medidas** com percentil nearest-rank. Não se inferem a partir de médias.
- Separar HTTP 429 (rejeição por capacidade), 5xx e timeout; não confundir rejeições com descarte silencioso.
- Vazão HTTP = requisições finalizadas por segundo; pedidos aceitos/s e processados/s vêm dos deltas das métricas da fila na janela.
- O benchmark do parser demonstra comportamento isolado; **não atribuir** ao parser uma mudança provocada pelo limite do semáforo.
- Capturas de counters e trace podem alterar o desempenho; ambas as rodadas usam a mesma instrumentação. A máquina Codespaces é compartilhada, portanto resultados possuem incerteza.
- O trace precisa ser **aberto e interpretado** para relacionar amostras/stacks a CPU ou esperas. A captura do arquivo, sozinha, não comprova gargalo.
- Metas só podem ser marcadas atendidas após leitura dos resultados reais, sem afirmar causalidade além da comparação.

## Extensão de aprimoramento
- Executar `rodar_cenario.sh degraus` após as duas rodadas, em instância nova, variando apenas a taxa de chegada de 8 até 40 requisições/s, para identificar saturação e registrar `degraus-resumo.md`.

## Evidências
- **R5.01**: este plano e versão do ambiente (`dotnet --info`), roteiro de reprodução.
- **R5.02**: relatório BenchmarkDotNet e CSV de counters coletado **durante a carga**.
- **R5.03**: trace real aberto no Speedscope/Visual Studio, com método/espera interpretados.
- **R5.04**: tabela `comparacao.md` com p50/p95/p99, vazão, erros, fila e testes funcionais de regressão.
MD

cat > HubPedidos.Relatorio5/carga.py <<'PY'
#!/usr/bin/env python3
"""Carga HTTP reproduzível com biblioteca padrão. Uso: python3 carga.py --url ... --out ..."""
import argparse
import concurrent.futures
import csv
import json
import math
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter
from pathlib import Path


def fetch(url, method='GET', data=None, timeout=5.0):
    start = time.perf_counter()
    req = urllib.request.Request(url, method=method,
        data=json.dumps(data).encode('utf-8') if data is not None else None,
        headers={'Content-Type': 'application/json'} if data is not None else {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            status = resp.status
            body = resp.read()
        return {'status': status, 'elapsed_ms': (time.perf_counter()-start)*1000, 'error': '', 'body': body}
    except urllib.error.HTTPError as exc:
        exc.read()
        return {'status': exc.code, 'elapsed_ms': (time.perf_counter()-start)*1000, 'error': '', 'body': b''}
    except Exception as exc:
        return {'status': 0, 'elapsed_ms': (time.perf_counter()-start)*1000,
                'error': type(exc).__name__, 'body': b''}


def metrics(url):
    data = fetch(url + '/api/pipeline/metricas')
    if data['status'] != 200:
        raise RuntimeError('Falha ao consultar metricas HTTP: ' + str(data['status']))
    return json.loads(data['body'])


def percentile(vals, pct):
    if not vals:
        return None
    vals = sorted(vals)
    return round(vals[max(0, math.ceil(pct * len(vals))-1)], 3)


def phase(url, status_id, rate, seconds, phase_name):
    todo = int(rate * seconds)
    results = []
    start = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=24) as workers:
        futures = []
        for i in range(todo):
            scheduled = start + i / rate
            sleep_for = scheduled - time.perf_counter()
            if sleep_for > 0:
                time.sleep(sleep_for)
            if i % 4 == 0:
                verb, path, payload = 'GET', f'/api/pipeline/status/{status_id}', None
            else:
                verb, path, payload = 'POST', '/api/pipeline/enfileirar', {'pedidoId': str(uuid.uuid4())}
            fut = workers.submit(fetch, url + path, verb, payload)
            futures.append((i, verb, fut))
        for i, verb, fut in futures:
            res = fut.result()
            results.append({'seq': i, 'phase': phase_name, 'method': verb,
                            'status': res['status'], 'latency_ms': round(res['elapsed_ms'], 3),
                            'error': res['error']})
    end = time.perf_counter()
    return results, round(end-start, 3)


def delta(after, before, key):
    # ASP.NET Core JSON usa camelCase por padrao.
    return int(after.get(key, 0)) - int(before.get(key, 0))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--url', default='http://127.0.0.1:5085')
    ap.add_argument('--out', required=True)
    ap.add_argument('--nome', required=True, choices=['antes', 'depois'])
    ap.add_argument('--rate', type=int, default=30)
    ap.add_argument('--warmup', type=int, default=5)
    ap.add_argument('--seconds', type=int, default=20)
    args = ap.parse_args()
    assert args.rate > 0 and args.seconds > 0 and args.warmup >= 0
    url = args.url.rstrip('/')
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    seed_id = str(uuid.uuid4())
    r = fetch(url + '/api/pipeline/enfileirar', 'POST', {'pedidoId': seed_id})
    if r['status'] != 202:
        raise RuntimeError(f'Nao foi possivel cadastrar pedido de consulta. HTTP {r["status"]}')
    print(f'R5.01 {args.nome}: warmup={args.warmup}s, coleta={args.seconds}s, taxa={args.rate}req/s, POST=75%, GET=25%', flush=True)
    if args.warmup:
        warm, _ = phase(url, seed_id, min(args.rate, 8), args.warmup, 'aquecimento')
        print(f'R5.01 {args.nome}: warmup descartado dos percentis: {len(warm)} requisicoes', flush=True)
        # Retirar carga residual da fila antes de iniciar a janela medida.
        for _ in range(30):
            m = metrics(url)
            if int(m['aceitos']) == int(m['processados']) + int(m['falhas']):
                break
            time.sleep(0.2)
    before = metrics(url)
    rows, elapsed = phase(url, seed_id, args.rate, args.seconds, 'medicao')
    after = metrics(url)
    latencies = [r['latency_ms'] for r in rows]
    counts = Counter(str(r['status']) for r in rows)
    timeouts = sum(bool(r['error']) for r in rows)
    failures = sum(r['status'] < 200 or r['status'] >= 400 for r in rows)
    post = [r for r in rows if r['method'] == 'POST']
    get = [r for r in rows if r['method'] == 'GET']

    def stats(items):
        vals = [r['latency_ms'] for r in items]
        return dict(qtd=len(items), p50_ms=percentile(vals, .5),
                    p95_ms=percentile(vals, .95), p99_ms=percentile(vals, .99))

    summary = dict(
        nome=args.nome, duracao_medicao_s=elapsed, planejadas_por_s=args.rate,
        aquecimento_s=args.warmup, total=len(rows), p50_ms=percentile(latencies,.5),
        p95_ms=percentile(latencies,.95), p99_ms=percentile(latencies,.99),
        requisicoes_por_s=round(len(rows)/elapsed, 3),
        erros_http=failures, taxa_erro_pct=round(100*failures/len(rows), 3),
        timeouts=timeouts, codigos_http=dict(counts), post=stats(post), get=stats(get),
        fila=dict(aceitos_delta=delta(after,before,'aceitos'),
                  processados_delta=delta(after,before,'processados'),
                  falhas_delta=delta(after,before,'falhas'),
                  rejeitados_delta=delta(after,before,'rejeitados'),
                  descartados_delta=delta(after,before,'descartados'),
                  pico_fila=after.get('picoFila'), pico_banco=after.get('picoBanco'),
                  espera_media_ms=after.get('esperaMediaMs'),
                  latencia_media_ms=after.get('latenciaMediaMs'),
                  profundidade_atual=after.get('profundidadeAtual'),
                  aceitos_por_s=round(delta(after,before,'aceitos')/elapsed,3),
                  processados_por_s=round(delta(after,before,'processados')/elapsed,3)),
    )
    with (out / f'{args.nome}-requisicoes.csv').open('w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=['seq','phase','method','status','latency_ms','error'])
        writer.writeheader()
        writer.writerows(rows)
    (out / f'{args.nome}-resumo.json').write_text(json.dumps(summary, indent=2, ensure_ascii=False), encoding='utf-8')
    print(f'R5.04 {args.nome}: HTTP p50={summary["p50_ms"]}ms p95={summary["p95_ms"]}ms p99={summary["p99_ms"]}ms req_s={summary["requisicoes_por_s"]}', flush=True)
    print(f'R5.04 {args.nome}: HTTP {dict(counts)} falhas={failures} timeouts={timeouts} taxa_erro_pct={summary["taxa_erro_pct"]}', flush=True)
    print(f'R5.04 {args.nome}: fila {summary["fila"]}', flush=True)
    print(f'R5.04 {args.nome}: arquivos gerados em {out}', flush=True)


if __name__ == '__main__':
    main()
PY

cat > HubPedidos.Relatorio5/comparar.py <<'PY'
#!/usr/bin/env python3
"""Gera tabela Markdown com resultados REAIS das duas execucoes."""
import json
import sys
from pathlib import Path

base = Path(__file__).resolve().parent / 'evidencias'
a = json.loads((base/'antes-resumo.json').read_text(encoding='utf-8'))
b = json.loads((base/'depois-resumo.json').read_text(encoding='utf-8'))


def fmt(x):
    if x is None: return 'n/d'
    if isinstance(x, float): return f'{x:.2f}'.replace('.',',')
    return str(x)

rows = [
 ('Limite simultâneo (parâmetro alterado)', 1, 2),
 ('Requisições medidas', a['total'], b['total']),
 ('p50 HTTP (ms)', a['p50_ms'], b['p50_ms']),
 ('p95 HTTP (ms)', a['p95_ms'], b['p95_ms']),
 ('p99 HTTP (ms)', a['p99_ms'], b['p99_ms']),
 ('Vazão HTTP (req/s)', a['requisicoes_por_s'], b['requisicoes_por_s']),
 ('Pedidos aceitos/s na janela', a['fila']['aceitos_por_s'], b['fila']['aceitos_por_s']),
 ('Pedidos processados/s na janela', a['fila']['processados_por_s'], b['fila']['processados_por_s']),
 ('HTTP 429', a['codigos_http'].get('429',0), b['codigos_http'].get('429',0)),
 ('Erros HTTP + conexões (%)', a['taxa_erro_pct'], b['taxa_erro_pct']),
 ('Timeouts/erros de transporte', a['timeouts'], b['timeouts']),
 ('Pico da fila', a['fila']['pico_fila'], b['fila']['pico_fila']),
 ('Pico de operações simultâneas', a['fila']['pico_banco'], b['fila']['pico_banco']),
 ('Espera média do canal (ms)', a['fila']['espera_media_ms'], b['fila']['espera_media_ms']),
]
lines = ['# R5.04 – Comparação antes/depois (medidas observadas)',
         '', '| Indicador | Antes | Depois |', '|---|---:|---:|']
lines += [f'| {label} | {fmt(v1)} | {fmt(v2)} |' for label,v1,v2 in rows]
lines += ['', 'Mudança única: `R4_LIMITE_BANCO=1` → `2`. Capacidade, consumidores, atraso, taxa, rotas e duração mantidos.',
          'Persistência simulada e medições no Codespaces; resultados não equivalem a medições do Neon.',
          'p50/p95/p99 calculados a partir dos tempos de cada requisição da janela medida; aquecimento excluído.',
          'HTTP 429 é rejeição por capacidade, não descarte. O trace requer análise separada antes de atribuir causa.',
          '', '## Interpretação baseada nas métricas',
          'Descreva se a alteração reduziu rejeições, mudou vazão, p95/p99 e espera. Não conclua melhora geral se alguma métrica piorou.',
          'Anexar captura dos testes funcionais após a alteração e análise de trace (R5.03).']
output = base/'comparacao.md'
output.write_text('\n'.join(lines)+'\n', encoding='utf-8')
print('\n'.join(lines))
print(f'\nTabela salva em: {output}')
PY

cat > HubPedidos.Relatorio5/degraus.py <<'PY'
#!/usr/bin/env python3
"""Extensao R5: carga progressiva para localizar faixa de saturacao."""
import argparse
import json
import uuid
from pathlib import Path
from carga import fetch, metrics, phase, percentile

parser = argparse.ArgumentParser()
parser.add_argument('--url', default='http://127.0.0.1:5085')
parser.add_argument('--out', required=True)
args = parser.parse_args()
url = args.url.rstrip('/')
out = Path(args.out)
out.mkdir(parents=True, exist_ok=True)
seed = str(uuid.uuid4())
r = fetch(url + '/api/pipeline/enfileirar', 'POST', {'pedidoId': seed})
if r['status'] != 202:
    raise RuntimeError(f'Pedido de consulta nao aceito. HTTP {r["status"]}')
rows = []
for rate in [8, 16, 24, 32, 40]:
    before = metrics(url)
    responses, secs = phase(url, seed, rate, 5, f'degrau_{rate}')
    after = metrics(url)
    errors = sum(x['status'] < 200 or x['status'] >= 400 for x in responses)
    item = {
        'carga_req_s': rate,
        'solicitacoes': len(responses),
        'p95_ms': percentile([x['latency_ms'] for x in responses], .95),
        'http_429': sum(x['status'] == 429 for x in responses),
        'taxa_erro_pct': round(100 * errors / len(responses), 2),
        'aceitos': after['aceitos'] - before['aceitos'],
        'processados': after['processados'] - before['processados'],
        'pico_fila': after['picoFila'],
        'duracao_s': secs,
    }
    rows.append(item)
    print(f'R5.04 DEGRAU: {item}', flush=True)
head = ['# Extensao R5 – Carga em degraus', '',
        '| Taxa ofertada (req/s) | p95 (ms) | HTTP 429 | Erros (%) | Aceitos | Processados |',
        '|---:|---:|---:|---:|---:|---:|']
for x in rows:
    head.append(f'| {x["carga_req_s"]} | {x["p95_ms"]} | {x["http_429"]} | {x["taxa_erro_pct"]} | {x["aceitos"]} | {x["processados"]} |')
head += ['', 'Teste progressivo sob a mesma instancia da API. Os deltas de processamento e fila refletem backlog acumulado; interpretar com cuidado.']
(out/'degraus-resumo.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
(out/'degraus-resumo.md').write_text('\n'.join(head)+'\n', encoding='utf-8')
print('\n'.join(head))
PY

cat > HubPedidos.Relatorio5/rodar_cenario.sh <<'SHC'
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
SHC

cat > HubPedidos.Relatorio5/.gitignore <<'GI'
# Evidencias brutas e logs locais: podem ficar extensos.
evidencias/*.nettrace
evidencias/*.speedscope.json
evidencias/*.log
evidencias/*.csv
__pycache__/
# Resumos e comparacao MD/JSON podem ser versionados sem credenciais.
GI

chmod +x HubPedidos.Relatorio5/rodar_cenario.sh HubPedidos.Relatorio5/carga.py HubPedidos.Relatorio5/comparar.py HubPedidos.Relatorio5/degraus.py
python3 -m py_compile HubPedidos.Relatorio5/carga.py HubPedidos.Relatorio5/comparar.py HubPedidos.Relatorio5/degraus.py
bash -n HubPedidos.Relatorio5/rodar_cenario.sh
printf '\n=== REGISTRANDO AMBIENTE REPRODUZIVEL ===\n'
{
  date -u '+UTC: %Y-%m-%d %H:%M:%S'
  printf 'Git branch: '; git branch --show-current
  printf 'Git commit: '; git rev-parse --short HEAD
  printf 'OS e arquitetura: '; uname -srm
  printf 'CPUs logicas: '; nproc
  grep -m1 '^model name' /proc/cpuinfo || true
  printf '\n.NET SDK e runtimes\n'
  dotnet --info
} > HubPedidos.Relatorio5/evidencias/ambiente.txt
printf '\n=== COMPILACAO RELEASE (sem alterar projetos existentes) ===\n'
dotnet build -c Release
printf '\n=== RELATORIO 5 PREPARADO ===\n'
printf 'Plano: HubPedidos.Relatorio5/plano.md\n'
printf 'Benchmark existente: HubPedidos.Benchmarks/ParserBenchmarks.cs\n'
printf 'Cenario 1: bash HubPedidos.Relatorio5/rodar_cenario.sh antes\n'
printf 'Cenario 2: bash HubPedidos.Relatorio5/rodar_cenario.sh depois\n'
printf 'Comparacao: python3 HubPedidos.Relatorio5/comparar.py\n'
printf 'Extensao (degraus): bash HubPedidos.Relatorio5/rodar_cenario.sh degraus\n'
