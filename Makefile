# Makefile — orquestra o ciclo de vida do Trio Data Challenge (S08).
# `make help` documenta cada alvo a partir do comentário `##` na própria linha.

.DEFAULT_GOAL := help
COMPOSE := docker compose

help:            ## mostra esta ajuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	 awk 'BEGIN {FS=":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

## ---------- ciclo de vida ----------
# Sem --profile: os 13 serviços do caminho principal sobem por padrão, para que
# o comando literal do PDF (`docker compose up -d`) funcione. Só o
# `cdc-experimento` é opt-in — ver `make up-cdc-experimento`.
up:              ## sobe o ambiente completo (13 serviços)
	$(COMPOSE) up -d
	@$(MAKE) wait-healthy

up-cdc-experimento: ## sobe também Redpanda/Debezium (artefato da decisão, ver ADR)
	$(COMPOSE) --profile cdc-experimento up -d
	@$(MAKE) wait-healthy

down:            ## derruba mantendo os dados
	$(COMPOSE) --profile cdc-experimento down

nuke:            ## APAGA TUDO, inclusive volumes
	$(COMPOSE) --profile cdc-experimento down -v
	@echo "volumes removidos — o próximo 'make seed' leva ~2 min"

wait-healthy:    ## aguarda todos os healthchecks
	@./scripts/wait-healthy.sh

## ---------- dados ----------
# Etapa 05 cria desafio-1/seed/generate_transactions.py; até lá o build local
# do serviço `seed` não tem Dockerfile e o alvo falha nomeando a etapa dona.
seed:            ## gera 10M de transações (~20 min) [requer etapa 05]
	@test -f desafio-1/seed/Dockerfile || { echo "ERRO: desafio-1/seed/Dockerfile não existe — script pertence à etapa 05 (seed-10m)"; exit 1; }
	$(COMPOSE) run --rm seed python generate_transactions.py

seed-force:      ## regenera do zero, ignorando o marcador [requer etapa 05]
	@test -f desafio-1/seed/Dockerfile || { echo "ERRO: desafio-1/seed/Dockerfile não existe — script pertence à etapa 05 (seed-10m)"; exit 1; }
	$(COMPOSE) run --rm seed python generate_transactions.py --force

indexes:         ## cria os índices (após o seed) [requer etapa 07]
	@test -f init/timescaledb/03_indexes.sql || { echo "ERRO: init/timescaledb/03_indexes.sql não existe — pertence à etapa 07 (indices-e-otimizacao)"; exit 1; }
	$(COMPOSE) exec -T timescaledb psql -U trio -d trio_transactions \
	  -f /docker-entrypoint-initdb.d/03_indexes.sql

policies:        ## cria CAggs, compressão e retenção [requer etapa 08]
	@test -f init/timescaledb/04_caggs_policies.sql || { echo "ERRO: init/timescaledb/04_caggs_policies.sql não existe — pertence à etapa 08 (caggs-compressao-retencao)"; exit 1; }
	$(COMPOSE) exec -T timescaledb psql -U trio -d trio_transactions \
	  -f /docker-entrypoint-initdb.d/04_caggs_policies.sql

## ---------- pipeline ----------
backfill:        ## carga inicial do ClickHouse [requer etapa 12]
	@test -f scripts/backfill-clickhouse.sh || { echo "ERRO: scripts/backfill-clickhouse.sh não existe — pertence à etapa 12 (backfill-e-query-subsegundo)"; exit 1; }
	./scripts/backfill-clickhouse.sh

pipeline:        ## registra o conector Debezium [requer etapa 13]
	@test -f scripts/register-connector.sh || { echo "ERRO: scripts/register-connector.sh não existe — pertence à etapa 13 (pipeline-cdc)"; exit 1; }
	./scripts/register-connector.sh

pipeline-status: ## estado do conector e lag [requer etapa 13]
	@curl -s localhost:8083/connectors/trio-transactions-connector/status | jq
	@docker exec trio-redpanda rpk group describe trio-cdc-consumer

## ---------- demonstrações ----------
demo:            ## demo de mutação de status (apresentação) [requer etapa 13]
	@test -f desafio-2/demo-mutation.sh || { echo "ERRO: desafio-2/demo-mutation.sh não existe — pertence à etapa 13 (pipeline-cdc)"; exit 1; }
	./desafio-2/demo-mutation.sh

demo-explain:    ## roda Q1-Q4 com EXPLAIN antes/depois [requer etapa 06]
	@test -f desafio-1/queries/run-explains.sh || { echo "ERRO: desafio-1/queries/run-explains.sh não existe — pertence à etapa 06 (queries-antes-indices)"; exit 1; }
	./desafio-1/queries/run-explains.sh

demo-restore:    ## exercício de recuperação completo [requer etapa 15]
	@test -f desafio-3/backup/restore-drill.sh || { echo "ERRO: desafio-3/backup/restore-drill.sh não existe — pertence à etapa 15 (backup-observabilidade-e-incidente)"; exit 1; }
	./desafio-3/backup/restore-drill.sh

demo-retention:  ## liga a retenção, mostra o efeito, restaura [requer etapa 08]
	@test -f desafio-1/scripts/retention-demo.sh || { echo "ERRO: desafio-1/scripts/retention-demo.sh não existe — pertence à etapa 08 (caggs-compressao-retencao)"; exit 1; }
	./desafio-1/scripts/retention-demo.sh

## ---------- operação ----------
backup:          ## backup manual dos três bancos [requer etapa 15]
	@test -f desafio-3/backup/run-all.sh || { echo "ERRO: desafio-3/backup/run-all.sh não existe — pertence à etapa 15 (backup-observabilidade-e-incidente)"; exit 1; }
	./desafio-3/backup/run-all.sh

logs:            ## logs do pipeline
	$(COMPOSE) logs -f cdc-consumer ref-sync

psql:            ## shell no TimescaleDB
	$(COMPOSE) exec timescaledb psql -U trio -d trio_transactions

psql-legado:     ## shell no legado
	$(COMPOSE) exec postgres-legado psql -U trio -d trio_legado

ch:              ## shell no ClickHouse
	$(COMPOSE) exec clickhouse clickhouse-client \
	  --user trio --password trio2024 --database trio_analytics

## ---------- verificação ----------
check:           ## valida que tudo está funcionando
	./scripts/health-check.sh

.PHONY: help up up-core down nuke wait-healthy seed seed-force indexes policies \
        backfill pipeline pipeline-status demo demo-explain demo-restore \
        demo-retention backup logs psql psql-legado ch check
