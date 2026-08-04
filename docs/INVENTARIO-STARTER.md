# Inventário do starter

O que os 4 arquivos de `init/` já trazem e qual etapa da esteira substitui ou estende cada um.

## `init/timescaledb/00_init.sql`
- Define hoje: `CREATE EXTENSION timescaledb CASCADE` + `pg_stat_statements`. Placeholder, sem tabela.
- Etapa 04 estende: cria `01_extensions.sql` mantendo essas duas extensões, acrescenta `02_schema.sql` (tabelas `accounts`, `transactions`, `reconciliation_events`, hypertables) e `03_policies.sql` (CAggs, compressão, retenção — etapa 08). Arquivo atual permanece como está ou vira `01_extensions.sql`; não é sobrescrito, é complementado.

## `init/postgres-legado/00_init.sql`
- Define hoje: só `pg_stat_statements`. Sem schema de usuários/contas.
- Etapa 10 estende: schema do banco legado (usuários, contas, configurações de parceiros) + seed sintético, conforme comentário-sugestão do próprio arquivo (`01_schema.sql`, `02_seed.sql`).

## `init/clickhouse/00_init.sql`
- Define hoje: `CREATE DATABASE trio_analytics`. Sem tabela.
- Etapa 11 estende: `01_schema.sql` (`transactions_raw` ReplacingMergeTree), etapa posterior acrescenta MVs (`AggregatingMergeTree` + view, sem `POPULATE`) e dictionary `dict_institutions` (etapa 14).

## `init/grafana/provisioning/datasources/datasources.yml`
- Define hoje: os 3 datasources completos (TimescaleDB, PostgreSQL Legado, ClickHouse) já configurados com credenciais do `.env.example`, `isDefault` no TimescaleDB.
- Etapa 15 estende: dashboards de observabilidade (não datasources — esses já estão prontos). Não deve mudar salvo se credenciais do `.env` mudarem.

## `docker-compose.yml`
- Define hoje: 4 serviços (timescaledb, postgres-legado, clickhouse, grafana), volumes nomeados, healthchecks, rede `trio-data-network`. `wal_level=logical` já habilitado no TimescaleDB (pré-requisito de CDC da etapa 13).
- Etapa 02 estende: acrescenta serviços novos (Redpanda, Debezium Connect, consumidor Python, MinIO) — não altera os 4 existentes salvo necessidade registrada.
