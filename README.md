export HUBPEDIDOS_DB='Host=ep-restless-cloud-b6c2vwtp-pooler.c-2.sa-east-1.aws.neon.tech;Port=5432;Database=neondb;Username=neondb_owner;Password=SENHA;SSL Mode=Require;Channel Binding=Require'

git switch main
git switch -c atividade-00-xxxx
git branch -D atividade-00-xxxx

atividade-01-contratos
atividade-02-performance
atividade-03-efcore
atividade-04-concorrencia
atividade-05-diagnostico
atividade-06-arquitetura
atividade-07-tempo-real

git branch -a

cd /workspaces/HubPedidos

git switch atividade-07-tempo-real

git status --short --branch

git add -A

git diff --cached --stat

git commit -m "Relatorio 7 - tempo-real"

git push -u origin atividade-07-tempo-real

git status -sb

*************
cd /workspaces/HubPedidos

git status -sb

git switch atividade-07-tempo-real

git restore --source atividade-06-arquitetura --staged --worktree :/

git status -sb

git commit -m "Copiar arquivos do Relatorio 6 para o Relatorio 7"

git push -u origin atividade-07-tempo-real

************
npg_ Tu0WUpKv 2HYM
