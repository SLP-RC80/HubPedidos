# Relatorio 7 – Roteiro de evidencias (UNIP ADS)

## R7.01 – SignalR e autorizacao
- Codigo: `PedidosHub.cs` mostra `[Authorize]` e checagem de `IPedidoAccessService` antes do grupo.
- Codigo: `Servicos.cs` mostra `SaveChangesAsync` ANTES de `EmitirAsync`.
- Terminal: `rodar_cliente.sh` mostra Alice autorizada, Bob rejeitado, evento Alice=1 / Bob=0.

## R7.02 – reconexao e reconciliacao
- Codigo: `HubPedidos.Relatorio7.Cliente/Program.cs`: `WithAutomaticReconnect`, callbacks `Reconnecting` e `Reconnected`, `Acompanhar` e GET apos reconexao.
- Terminal `rodar_cliente.sh`: `Reconectando -> Conectado; reingresso=SIM; reconciliado=SIM`.
- O evento perdido nao e reproduzido automaticamente: HTTP GET e estado autoritativo.

## R7.03 – ETag / If-None-Match / If-Match
- Codigo: `Dados.cs` / `ApiEndpoints.cs`: SHA256 estavel, cabecalho ETag e 304 sem corpo.
- Terminal `testar_http.sh`: 200, 304, bytes=0; `rodar_cliente.sh`: novo ETag e HTTP 412 para If-Match obsoleto.

## R7.04 – Output Cache somente publico
- Codigo: `Program.cs`: politica CatalogoPublico, SetVaryByQuery("regiao"), tag de invalidação; rotas privadas nao usam `.CacheOutput`.
- Codigo: `Servicos.cs`: `EvictByTagAsync` APOS escrita.
- Terminal: SP HIT, RJ variacao, SP invalidado apos alteracao.

## Regressao
- Testes novos: `dotnet test ... --filter FullyQualifiedName~Relatorio7TempoRealTests` (8 testes se todos passarem).
- Geral: `dotnet test -c Release ...` (esperados 59, os 51 anteriores + 8 novos, se todos passarem).

> A autenticacao por chaves aleatorias locais e exclusivamente didatica. Nao publicar a porta 5087 publicamente.
> Este R7 usa SQLite local para demonstrar SaveChanges e a ordem persistencia/evento; o Neon dos relatorios anteriores permanece intacto.
> As credenciais em `.secrets/` e a base `.data/` sao ignoradas pelo Git. Nunca fazer print das chaves.
