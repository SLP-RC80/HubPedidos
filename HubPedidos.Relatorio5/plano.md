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
