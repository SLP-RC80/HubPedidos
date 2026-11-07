# HubPedidos
export HUBPEDIDOS_DB='Host=ep-restless-cloud-b6c2vwtp.c-2.sa-east-1.aws.neon.tech;Port=5432;Database=neondb;Username=neondb_owner;Password=npg_KAUWEoOCLv65;SSL Mode=Require;Channel Binding=Require'

git branch
git branch -r
git branch -a

cd /workspaces/HubPedidos

git status --short --branch

git add -A

git diff --cached --stat

git commit -m "Relatorio 5 - diagnostico, perfilamento e evidencias"
git push -u origin atividade-05-diagnostico

cd /workspaces/HubPedidos

git status --short --branch

git switch -c atividade-06-arquitetura

cd /workspaces/HubPedidos

git push origin --all