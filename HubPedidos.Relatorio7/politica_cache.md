# Politica de cache e revalidacao R7

- Rotas privadas `/api/v1/pedidos/{id}`: autorizacao de usuario + ETag forte baseada na representacao do pedido; HTTP 304 sem corpo apenas apos validar a propriedade do pedido. NAO habilitar Output Cache compartilhado.
- Rotas de alteracao: `If-Match` obrigatorio; ausencia -> HTTP 428; ETag desatualizada -> HTTP 412. A versao interna EF Core e token de concorrencia.
- Rota publica `/api/publico/catalogo-status?regiao=SP`: Output Cache por 10 min, variando por `regiao`. Invalida a tag `catalogo-status` apos persistencia do novo estado.
- SignalR: grupos filtram destinatarios, mas nao substituem autorizacao. Reingresso apos reconexao precisa autorizar novamente e consultar GET HTTP.
- Identificacao local de usuario: chave aleatoria em arquivo ignorado no Git, adequada apenas a exercicio controlado; requer provedor de identidade real para producao.
