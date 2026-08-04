# TimescaleDB + pgBackRest na mesma imagem.
#
# Por que derivar em vez de instalar em runtime: pgBackRest precisa rodar DENTRO
# do container do banco — ele lê o PGDATA e é chamado pelo archive_command a cada
# segmento de WAL. Instalar via `docker exec` funcionaria até o primeiro
# `docker compose down`, e aí o archive_command voltaria a falhar com exit 127,
# que foi exatamente o que encheu o pg_wal com 17,7 GB antes do E0.
FROM timescale/timescaledb:latest-pg16

# Versão não fixada de propósito: o repositório Alpine da imagem base só carrega
# uma, e fixar aqui quebraria o build quando ela avançasse.
RUN apk add --no-cache pgbackrest

# O pgBackRest roda como o usuário postgres e precisa desses caminhos.
RUN mkdir -p /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest \
 && chown -R postgres:postgres /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest

COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
RUN chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
COPY minio-ca.crt /etc/pgbackrest/minio-ca.crt
