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
