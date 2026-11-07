export HUBPEDIDOS_DB='Host=ep-restless-cloud-b6c2vwtp.c-2.sa-east-1.aws.neon.tech;Port=5432;Database=neondb;Username=neondb_owner;Password=npg_KAUWEoOCLv65;SSL Mode=Require;Channel Binding=Require'

git switch main

atividade-01-contratos
atividade-02-performance
atividade-03-efcore
atividade-04-concorrencia
atividade-05-diagnostico
atividade-06-arquitetura

git branch -a

cd /workspaces/HubPedidos

git switch atividade-06-arquitetura

git status --short --branch

git add -A

git diff --cached --stat

git commit -m "Relatorio 6 - arquitetura"

git push -u origin atividade-06-arquitetura

git status -sb