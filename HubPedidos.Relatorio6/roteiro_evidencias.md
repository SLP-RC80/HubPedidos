# Controle das capturas – Relatorio 6

| ID | Momento exato | Evidencia |
|---|---|---|
| R6.01-A | Abrir `arquitetura.md` em Preview, exibindo o diagrama | Fronteiras dos 3 modulos, Domain e API |
| R6.01-B | `dotnet list HubPedidos.Modulos.Pedidos/HubPedidos.Modulos.Pedidos.csproj reference` + testes de fronteira | Referencias e isolamento do dominio |
| R6.02-A | Abrir `ModulosRegistracao.cs` e `Program.cs` | Tres extensoes `Add*Module`, lifetimes e chamada no composition root |
| R6.02-B | Filtrar `Relatorio6ArquiteturaTests` | Testes de DI valido e singleton capturando scoped rejeitado |
| R6.03-A | `curl http://localhost:5086/openapi/v1.json` com lista das rotas | Documentacao de v1/v2, ambas presentes |
| R6.03-B | `bash HubPedidos.Relatorio6/testar_http.sh` | Retorno HTTP 200 v1, 200 v2 e contratos distintos |
| R6.04-A | `dotnet run --project HubPedidos.Relatorio6.ClienteV1 -c Release` | Cliente v1 funciona sem alteracao; politica 404/404 |
| R6.04-B | `dotnet test ... --filter FullyQualifiedName~Relatorio6ArquiteturaTests` | Oito testes especificos aprovados |
| R6.04-C | `dotnet test -c Release` (Neon ativo para testes R3) | Suíte geral aprovada |

Capturas de codigo podem mostrar so trecho. Na consolidacao Word, listar os caminhos integrais na secao 3.6.
