# PostgreSQL legado + pgBackRest. Mesma justificativa da imagem do TimescaleDB.
# O PDF § 5.2 A.1 cobra estratégia de backup para os TRÊS bancos — o legado não
# é opcional só por ser legado.
FROM postgres:16-bookworm

# O repositório PGDG já está configurado na imagem oficial do Postgres.
RUN apt-get update \
 && apt-get install -y --no-install-recommends pgbackrest \
 && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest \
 && chown -R postgres:postgres /var/log/pgbackrest /var/lib/pgbackrest /etc/pgbackrest

COPY pgbackrest.conf /etc/pgbackrest/pgbackrest.conf
RUN chown postgres:postgres /etc/pgbackrest/pgbackrest.conf
COPY minio-ca.crt /etc/pgbackrest/minio-ca.crt
