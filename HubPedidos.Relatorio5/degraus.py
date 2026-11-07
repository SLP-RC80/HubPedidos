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
