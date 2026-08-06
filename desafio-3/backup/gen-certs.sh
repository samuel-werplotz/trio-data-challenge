#!/usr/bin/env bash
# gen-certs.sh — gera o certificado auto-assinado que o MinIO usa para servir
# HTTPS. Necessário porque o pgBackRest com repo1-type=s3 sempre fala TLS:
# repo-storage-port tem default 443 e não há opção de pedir HTTP puro.
#
# A chave privada NÃO é versionada (.gitignore). Rode isto após clonar o repo,
# antes do primeiro `docker compose up`.
set -euo pipefail
export MSYS_NO_PATHCONV=1

DIR="$(cd "$(dirname "$0")" && pwd)/minio-certs"
mkdir -p "$DIR"

docker run --rm -v "$DIR":/out alpine sh -c "
  apk add --no-cache openssl >/dev/null 2>&1
  openssl req -new -x509 -nodes -days 3650 \
    -subj '/C=BR/ST=SP/O=Trio/CN=minio' \
    -addext 'subjectAltName=DNS:minio,DNS:localhost,IP:127.0.0.1' \
    -keyout /out/private.key -out /out/public.crt >/dev/null 2>&1
  chmod 644 /out/private.key /out/public.crt"

# O CA precisa entrar nas imagens dos bancos: é como o pgBackRest valida o
# certificado do MinIO, em vez de simplesmente desligar a verificação.
cp "$DIR/public.crt" "$(dirname "$0")/timescaledb/minio-ca.crt"
cp "$DIR/public.crt" "$(dirname "$0")/postgres-legado/minio-ca.crt"

echo "certificado gerado em $DIR"
echo "CA copiado para o contexto de build de timescaledb e postgres-legado"

# O CA vai para dentro da imagem via COPY (ver os dois Dockerfiles), então
# gerar um certificado novo SEM reconstruir deixa as imagens com o CA antigo:
# o pgBackRest recusa o MinIO com "unable to verify certificate presented by
# 'minio:9000': self-signed certificate", o archive_command falha em silêncio e
# `pg_stat_archiver` acumula centenas de failed_count — sem nada quebrar de
# forma visível. Foi o que aconteceu num teste de clone limpo, com os dois
# Postgres afetados. Por isso o rebuild acontece aqui, e não numa instrução
# impressa que se espera que alguém leia e execute.
COMPOSE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$COMPOSE_DIR"

echo "reconstruindo as imagens dos bancos com o CA novo…"
docker compose build timescaledb postgres-legado >/dev/null 2>&1 \
  && echo "  imagens reconstruídas" \
  || echo "  AVISO: build falhou — rode 'docker compose build timescaledb postgres-legado'"

# Se os containers já estiverem de pé, eles seguem com a imagem antiga até
# serem recriados. `up -d` recria só o que mudou; se nada estiver rodando, é
# no-op e o `up` seguinte da sequência faz o trabalho.
if [ -n "$(docker compose ps -q timescaledb postgres-legado 2>/dev/null)" ]; then
  echo "bancos já em execução — recriando com a imagem nova…"
  docker compose up -d --force-recreate timescaledb postgres-legado >/dev/null 2>&1 \
    && echo "  containers recriados" \
    || echo "  AVISO: recriação falhou — rode 'docker compose up -d --force-recreate timescaledb postgres-legado'"
fi
