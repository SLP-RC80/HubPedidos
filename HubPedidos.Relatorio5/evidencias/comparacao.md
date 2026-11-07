# R5.04 – Comparação antes/depois (medidas observadas)

| Indicador | Antes | Depois |
|---|---:|---:|
| Limite simultâneo (parâmetro alterado) | 1 | 2 |
| Requisições medidas | 600 | 600 |
| p50 HTTP (ms) | 1,33 | 1,29 |
| p95 HTTP (ms) | 2,23 | 2,27 |
| p99 HTTP (ms) | 3,50 | 4,15 |
| Vazão HTTP (req/s) | 30,05 | 30,05 |
| Pedidos aceitos/s na janela | 18,73 | 22,53 |
| Pedidos processados/s na janela | 16,52 | 22,43 |
| HTTP 429 | 76 | 0 |
| Erros HTTP + conexões (%) | 12,67 | 0,00 |
| Timeouts/erros de transporte | 0 | 0 |
| Pico da fila | 40 | 1 |
| Pico de operações simultâneas | 1 | 2 |
| Espera média do canal (ms) | 1610,08 | 0,10 |

Mudança única: `R4_LIMITE_BANCO=1` → `2`. Capacidade, consumidores, atraso, taxa, rotas e duração mantidos.
Persistência simulada e medições no Codespaces; resultados não equivalem a medições do Neon.
p50/p95/p99 calculados a partir dos tempos de cada requisição da janela medida; aquecimento excluído.
HTTP 429 é rejeição por capacidade, não descarte. O trace requer análise separada antes de atribuir causa.

## Interpretação baseada nas métricas
Descreva se a alteração reduziu rejeições, mudou vazão, p95/p99 e espera. Não conclua melhora geral se alguma métrica piorou.
Anexar captura dos testes funcionais após a alteração e análise de trace (R5.03).
