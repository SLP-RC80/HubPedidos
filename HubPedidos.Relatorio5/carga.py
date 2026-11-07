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
