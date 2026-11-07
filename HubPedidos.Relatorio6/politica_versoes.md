# R6.03/R6.04 – Politica de versionamento e transicao

- Selecao explicita por URL: `GET /api/v1/pedidos/{id}` e `GET /api/v2/pedidos/{id}`.
- V1 mantida: `{ "id": "...", "status": "Processando", "total": 80.00 }`.
- V2 incompatível, somente na nova rota: `{ "id": "...", "situacao": { "codigo": "EM_PROCESSAMENTO", "descricao": "Pedido em processamento" }, "total": { "valor": 80.00, "moeda": "BRL" } }`.
- Sem versao (`/api/pedidos/{id}`) e versao nao suportada (`/api/v3/...`) retornam HTTP **404**; nao ha substituicao silenciosa.
- O endpoint `/api/metricas/versoes` demonstra contagem de acesso bem-sucedido a v1.
- Uma futura descontinuacao exige monitorar clientes v1, comunicar migracao e definir cronograma. Esta atividade **nao** remove v1 e nao estabelece prazo de desativacao.
- Documento OpenAPI disponivel em `/openapi/v1.json` (nome do documento OpenAPI, **nao** somente a versao de rotas); ambas as rotas devem aparecer na secao `paths`.
