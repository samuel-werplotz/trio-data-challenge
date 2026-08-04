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
echo "CA copiado para as imagens de timescaledb e postgres-legado"
echo "reconstrua os bancos:  docker compose --profile core build timescaledb postgres-legado"
