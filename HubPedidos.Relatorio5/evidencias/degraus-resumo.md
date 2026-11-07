# Extensao R5 – Carga em degraus

| Taxa ofertada (req/s) | p95 (ms) | HTTP 429 | Erros (%) | Aceitos | Processados |
|---:|---:|---:|---:|---:|---:|
| 8 | 6.259 | 0 | 0.0 | 30 | 30 |
| 16 | 2.407 | 0 | 0.0 | 60 | 60 |
| 24 | 2.764 | 0 | 0.0 | 90 | 89 |
| 32 | 1.95 | 0 | 0.0 | 120 | 120 |
| 40 | 1.696 | 0 | 0.0 | 150 | 149 |

Teste progressivo sob a mesma instancia da API. Os deltas de processamento e fila refletem backlog acumulado; interpretar com cuidado.
