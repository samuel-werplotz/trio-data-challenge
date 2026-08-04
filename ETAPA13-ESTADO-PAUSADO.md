# Etapa 13 — pausada para reavaliação de arquitetura (2026-08-04)

## O que funcionou (confirmado, testado de ponta a ponta)

1. `publish_via_partition_root = true` funcionou sobre a hypertable — evento chegou no tópico `trio.public.transactions` (nome da tabela-mãe), sem precisar do RegexRouter de fallback.
2. Consumidor Python (`desafio-2/pipeline/consumer/`) completo: `main.py`, `transform.py`, `sink.py`, `metrics.py` — laço principal, micro-batch, retry exponencial, DLQ, métricas Prometheus em `:8001/metrics`.
3. `demo-mutation.sh` rodou com sucesso (antes do travamento): INSERT→pending no CH, UPDATE→settled no CH via FINAL, 2 linhas sem FINAL demonstrando o mecanismo do ReplacingMergeTree, OPTIMIZE colapsando para 1 linha.
4. DLQ testada: evento malformado não derrubou o consumidor, foi para `trio.dlq.transactions` com o motivo no header.
5. Idempotência testada: reprocessamento do offset 0 manteve `count() FINAL` idêntico.

## O que travou

Depois de um erro meu (apaguei 3 linhas de `transactions` achando que eram sintéticas de teste; 1 delas — id=10000000 — era dado real do seed original), fiz reseed completo dos 10M via `make seed-force`. Isso gerou um `TRUNCATE transactions` seguido de `COPY` de 10M linhas em paralelo (6 workers, ~2m43s).

A partir daí, o Debezium/pgoutput **parou de avançar** o `confirmed_flush_lsn` do slot de replicação lógica, mesmo com:
- Restart do container Debezium (recuperou brevemente, ~10s de progresso, travou de novo).
- Slot recriado do zero (`pg_drop_replication_slot` + novo `CREATE PUBLICATION`... na verdade a publication não mudou, só o slot).
- `table.include.list` restrito de `public.transactions,_timescaledb_internal.*` (338 chunks rastreados individualmente) para só `public.transactions`.

Em ambas as tentativas: conector fica `RUNNING`, task fica `RUNNING`, sem exceção nos logs, CPU do container baixa (<5%), sem sinal de OOM/GC pressure. `confirmed_flush_lsn` avança um pouco (alguns MB) e trava — reproduzido de forma idêntica 2 vezes.

## Diagnóstico não concluído

Não identifiquei a causa raiz. Hipóteses levantadas e não confirmadas nem descartadas com certeza:
- Overhead de decodificar 338 chunks individualmente (testado reduzir — não resolveu, então provavelmente não é a causa principal).
- Transação(ões) específica(s) do `COPY` paralelo do reseed com volume grande o suficiente para travar a decodificação lógica.
- Bug/limitação do pgoutput decoder do Debezium 2.7.3 especificamente contra o padrão de escrita do TimescaleDB (hypertable com centenas de chunks).
- Não foi possível fazer thread dump (jstack indisponível na imagem `debezium/connect:2.7.3.Final`) para confirmar onde a JVM está presa.

## Estado atual do ambiente (nada foi apagado)

- `transactions` (TimescaleDB): 10.000.002 linhas — 10.000.000 do reseed + 2 linhas de teste sintéticas (`id=20000354`, `id=20000355`, `source_institution='DEMO-CDC'`, `status='pending'`, nunca propagadas ao ClickHouse).
- `transactions_raw` (ClickHouse): 10.000.000 linhas — backfill íntegro, confirmado via `count()`/`count() FINAL`/contagem por mês contra o TimescaleDB, **antes** do travamento do CDC.
- `daily_by_institution`/`status_funnel` (ClickHouse): populadas e conferidas via `countMerge` = 10.000.000.
- Slot `trio_cdc_slot`: ativo, `confirmed_flush_lsn = 3/65D24C8`, parado.
- Conector `trio-transactions-connector`: `RUNNING` (mas não emitindo eventos novos).
- Containers: todos `Up`/`healthy` (`timescaledb`, `postgres-legado`, `clickhouse`, `redpanda`, `debezium`, `cdc-consumer`).
- `desafio-2/pipeline/consumer/` completo e funcional (testado antes do travamento).
- `desafio-2/demo-mutation.sh` completo e funcional (testado antes do travamento).
- `docker-compose.yml`: `debezium` corrigido de `debezium/connect:2.7` (tag inexistente) para `debezium/connect:2.7.3.Final` — bug real de digitação em S08, não decisão de arquitetura.

## Arquivos criados nesta etapa (não commitados ainda)

- `init/timescaledb/` — nada novo (publication criada via SQL manual, não arquivo).
- `desafio-2/pipeline/consumer/{main,config,transform,sink,metrics}.py`, `requirements.txt`, `Dockerfile`
- `desafio-2/demo-mutation.sh`
- `docker-compose.yml` (fix de tag)

## Decisão pendente do usuário

Reavaliar se aciona o plano B de S05 (micro-batch por watermark, reaproveitando `sink.py`/`metrics.py` já escritos) ou investiga mais a causa do travamento do Debezium antes de decidir.
