export HUBPEDIDOS_DB='Host=ep-restless-cloud-b6c2vwtp-pooler.c-2.sa-east-1.aws.neon.tech;Port=5432;Database=neondb;Username=neondb_owner;Password=SENHA;SSL Mode=Require;Channel Binding=Require'

git switch main
git switch -c atividade-08-qualidade
git branch -D atividade-00-xxxx

atividade-01-contratos
atividade-02-performance
atividade-03-efcore
atividade-04-concorrencia
atividade-05-diagnostico
atividade-06-arquitetura
atividade-07-tempo-real
atividade-08-qualidade

git branch -a

cd /workspaces/HubPedidos

git switch atividade-08-qualidade

git status --short --branch

git add -A

git diff --cached --stat

git commit -m "Relatorio 8 - qualidade"

git push -u origin atividade-08-qualidade

git status -sb

*************
cd /workspaces/HubPedidos

git status -sb

git switch atividade-08-qualidade

git restore --source atividade-07-tempo-real --staged --worktree :/

git status -sb

git commit -m "Copiar arquivos do Relatorio 7 para o Relatorio 8"

git push -u origin atividade-08-qualidade

************
npg_ Tu0WUpKv 2HYM
