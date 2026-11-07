# R8 – Qualidade continua | roteiro de capturas

## R8.01 – Fabrica e isolamento
- Abrir `HubPedidos.IntegrationTests/FabricasDeTeste.cs`: `WebApplicationFactory<R7::Program>`, ambiente `Testing`, `ConfigureTestServices` e `RemoveAll`.
- Mostrar `SqliteConnection("Data Source=:memory:")` mantida aberta e descartada pela fixture.
- Mostrar testes `R8_01_...` aprovados; nao existe acesso ao Neon nessa fabrica.

## R8.02 – Contratos e fila
- Abrir `Relatorio8HttpTests.cs`: criacao de dado pela fixture, GET privado, v1/v2, ETag/304, autorizacao, cache.
- Abrir `Relatorio8FilaTests.cs`: POST HTTP R4, persistencia fake e sincronizacao `TaskCompletionSource`, sem esperas arbitrarias.
- `dotnet test HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj -c Release --logger 'console;verbosity=normal'`.

## R8.03 – Analisador e formatacao
- Mostrar `.editorconfig` do R8 com CA2200 em error.
- Rodar `bash HubPedidos.Relatorio8/ativar_falha_analisador.sh` e `dotnet build HubPedidos.IntegrationTests -c Release`.
- CAPTURAR build falhando em CA2200; executar `bash HubPedidos.Relatorio8/limpar_falhas.sh`.
- Rodar `dotnet format HubPedidos.IntegrationTests/HubPedidos.IntegrationTests.csproj --verify-no-changes --no-restore --severity error` para gate verde.

## R8.04 – CI GitHub Actions
- Arquivo `.github/workflows/r8-qualidade.yml`: restore, build, format, testes, artefatos TRX.
- Provar a falha: criar branch a partir de atividade-08-qualidade, incluir falha de teste temporaria, push, print Actions vermelho.
- Reverter a falha temporaria na atividade-08-qualidade e executar workflow; print Actions verde e download/visualizacao artefato TRX.
- IMPORTANTE: teste DB R3 depende Neon; CI offline EXCLUI explicitamente Relatorio3DbTests.
- Na maquina Codespaces com `HUBPEDIDOS_DB` correto executar suite geral (59 anteriores) e R8 separado.

## Limites
- WebApplicationFactory R7 e R6 usam os hosts reais existentes, sem criar uma API fake duplicada.
- R7 nao oferece POST /api/v1/pedidos; a criacao de pedido do R8 ocorre na fixture SQLite e a consulta e via HTTP.
- O POST HTTP real de criacao de trabalho/fila e exercitado no host R4, com fake de persistencia observavel.
- SQLite nao substitui os testes especificos de Npgsql/PostgreSQL.
- Nunca commitar connection strings, .secrets/, bancos .db ou logs com tokens.
