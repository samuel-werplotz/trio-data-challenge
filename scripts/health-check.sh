#!/usr/bin/env bash
# health-check.sh — prova em uma passada se o ambiente está íntegro (S08).
# Uma linha por verificação (✓/✗), exit code agregado. Primeiro comando da demo.
set -uo pipefail

FAIL=0
COMPOSE="docker compose"

# line <ok?> <label> <detalhe> — imprime ✓/✗ e acumula falha
line() {
  local ok="$1" label="$2" detail="$3"
  if [ "$ok" -eq 0 ]; then
    printf '\033[32m✓\033[0m %-18s %s\n' "$label" "$detail"
  else
    printf '\033[31m✗\033[0m %-18s %s\n' "$label" "$detail"
    FAIL=1
  fi
}

svc_up() { [ -n "$($COMPOSE ps -q "$1" 2>/dev/null)" ]; }

# ---------- timescaledb ----------
if svc_up timescaledb; then
  N=$($COMPOSE exec -T timescaledb psql -U trio -d trio_transactions -tAc \
      "SELECT count(*) FROM transactions" 2>/dev/null || echo "")
  CHUNKS=$($COMPOSE exec -T timescaledb psql -U trio -d trio_transactions -tAc \
      "SELECT count(*) FROM timescaledb_information.chunks WHERE hypertable_name='transactions'" 2>/dev/null || echo "")
  if [ -n "$N" ]; then
    line 0 timescaledb "respondendo · $N transações · $CHUNKS chunks"
  else
    line 1 timescaledb "container de pé, tabela 'transactions' ainda não existe (etapa 04)"
  fi
else
  line 1 timescaledb "container fora do ar"
fi

# ---------- postgres-legado ----------
if svc_up postgres-legado; then
  N=$($COMPOSE exec -T postgres-legado psql -U trio -d trio_legado -tAc \
      "SELECT count(*) FROM institutions" 2>/dev/null || echo "")
  if [ -n "$N" ]; then
    line 0 postgres-legado "respondendo · $N instituições"
  else
    line 1 postgres-legado "container de pé, tabela 'institutions' ainda não existe (etapa 10)"
  fi
else
  line 1 postgres-legado "container fora do ar"
fi

# ---------- clickhouse ----------
if svc_up clickhouse; then
  N=$($COMPOSE exec -T clickhouse clickhouse-client --user trio --password trio2024 \
      --query "SELECT count() FROM trio_analytics.transactions_raw" 2>/dev/null || echo "")
  PARTS=$($COMPOSE exec -T clickhouse clickhouse-client --user trio --password trio2024 \
      --query "SELECT uniqExact(partition) FROM system.parts WHERE table='transactions_raw'" 2>/dev/null || echo "")
  if [ -n "$N" ]; then
    line 0 clickhouse "respondendo · $N linhas · $PARTS partições"
  else
    line 1 clickhouse "container de pé, tabela 'transactions_raw' ainda não existe (etapa 11)"
  fi
else
  line 1 clickhouse "container fora do ar"
fi

# ---------- redpanda ----------
if svc_up redpanda; then
  if $COMPOSE exec -T redpanda rpk cluster health 2>/dev/null | grep -q 'Healthy:.*true'; then
    NP=$($COMPOSE exec -T redpanda rpk topic list 2>/dev/null | wc -l)
    line 0 redpanda "saudável · $NP tópico(s)"
  else
    line 1 redpanda "container de pé, cluster não saudável ainda"
  fi
else
  line 1 redpanda "container fora do ar (perfil full, etapa 13)"
fi

# ---------- debezium ----------
if svc_up debezium; then
  STATUS=$(curl -sf localhost:8083/connectors/trio-transactions-connector/status 2>/dev/null \
           | grep -o '"state":"[A-Z]*"' | head -1)
  if [ -n "$STATUS" ]; then
    line 0 debezium "conector $STATUS"
  else
    line 1 debezium "container de pé, conector ainda não registrado (etapa 13)"
  fi
else
  line 1 debezium "container fora do ar (perfil full, etapa 13)"
fi

# ---------- cdc-consumer ----------
if svc_up cdc-consumer; then
  line 0 cdc-consumer "container de pé"
else
  line 1 cdc-consumer "container fora do ar (perfil full, etapa 13 — sem Dockerfile ainda)"
fi

# ---------- grafana ----------
if svc_up grafana; then
  N=$(curl -sf -u admin:admin localhost:3000/api/search 2>/dev/null | grep -o '"id"' | wc -l)
  line 0 grafana "$N dashboard(s) provisionados"
else
  line 1 grafana "container fora do ar"
fi

# ---------- prometheus ----------
if svc_up prometheus; then
  N=$(curl -sf localhost:9090/api/v1/targets 2>/dev/null | grep -o '"health":"up"' | wc -l)
  line 0 prometheus "$N alvo(s) ativos"
else
  line 1 prometheus "container fora do ar (perfil full, requer init/prometheus da etapa 15)"
fi

# ---------- minio ----------
if svc_up minio; then
  if curl -sf localhost:9002/minio/health/live >/dev/null 2>&1; then
    line 0 minio "respondendo"
  else
    line 1 minio "container de pé, não responde ainda"
  fi
else
  line 1 minio "container fora do ar (perfil full, etapa 15)"
fi

echo "----"
if [ "$FAIL" -eq 0 ]; then
  echo "Ambiente íntegro."
else
  echo "Ambiente incompleto — ✗ acima aponta a etapa que resolve."
fi
exit "$FAIL"
