# R6.01 – Grafo de modulos (referencias reais de projeto)

```mermaid
flowchart TD
    API["HubPedidos.Relatorio6 (API / composition root)"] --> PED["HubPedidos.Modulos.Pedidos"]
    API --> PROC["HubPedidos.Modulos.Processamento"]
    API --> NOTI["HubPedidos.Modulos.Notificacoes"]
    PROC --> PED
    NOTI --> PED
    PED --> DOM["HubPedidos.Domain (regras independentes)"]
    CLIENT["HubPedidos.Relatorio6.ClienteV1"] -. "HTTP v1 (sem referencia de projeto)" .-> API
```

Verificacao: `dotnet list <projeto.csproj> reference` e testes de referencia entre assemblies.
O projeto **Domain** nao deve referenciar a API, a infraestrutura nem EF Core.
A infraestrutura dos relatorios anteriores continua preservada; este exemplo usa repositorio em memoria somente em R6.
