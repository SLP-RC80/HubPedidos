#!/usr/bin/env bash
set -euo pipefail
cd /workspaces/HubPedidos

echo '=== PostgreSQL local de desenvolvimento para o Relatorio 3 ==='
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo 'Docker daemon nao esta disponivel neste Codespace.'
  echo 'Alternativa: banco PostgreSQL externo (Neon) com secret HUBPEDIDOS_DB.'
  exit 2
fi

if [[ -f .env.relatorio3 ]]; then
  echo 'Arquivo .env.relatorio3 ja existe; nao sobrescrevendo credenciais.'
  if ! docker container inspect hubpedidos-r3-db >/dev/null 2>&1; then
    echo 'Container ausente; revise ambiente antigo antes de recriar o banco.'
    exit 3
  fi
else
  if docker container inspect hubpedidos-r3-db >/dev/null 2>&1; then
    echo 'Container ja existe e credenciais locais nao foram encontradas.'
    echo 'Nao gerei nova senha: recupere a configuracao original ou use banco novo.'
    exit 3
  fi
  if command -v openssl >/dev/null 2>&1; then
    senha="$(openssl rand -hex 18)"
  else
    senha="$(od -An -N18 -tx1 /dev/urandom | tr -d ' \n')"
  fi
  conn="Host=127.0.0.1;Port=55432;Database=hubpedidos;Username=hubuser;Password=$senha"
  (umask 077; printf 'export HUBPEDIDOS_DB=%q\n' "$conn" > .env.relatorio3)
  chmod 600 .env.relatorio3
  docker run -d --name hubpedidos-r3-db \
    -p 127.0.0.1:55432:5432 \
    -e POSTGRES_DB=hubpedidos \
    -e POSTGRES_USER=hubuser \
    -e POSTGRES_PASSWORD="$senha" \
    -v hubpedidos_r3_pgdata:/var/lib/postgresql/data \
    postgres:16-alpine >/dev/null
  unset senha conn
fi

if [[ "$(docker inspect -f '{{.State.Running}}' hubpedidos-r3-db)" != 'true' ]]; then
  docker start hubpedidos-r3-db >/dev/null
fi
for t in $(seq 1 40); do
  if docker exec hubpedidos-r3-db pg_isready -U hubuser -d hubpedidos >/dev/null 2>&1; then
    echo 'POSTGRES DISPONIVEL: container hubpedidos-r3-db na porta local 55432'
    echo 'CREDENCIAIS NAO EXIBIDAS. Carregue: source .env.relatorio3'
    echo 'NAO inclua .env.relatorio3 em commits, documentos ou capturas.'
    exit 0
  fi
  sleep 1
done
echo 'PostgreSQL nao respondeu ao healthcheck; inspecione: docker logs hubpedidos-r3-db (sem mostrar credenciais).'
exit 4
