#!/usr/bin/env bash
# health-check.sh — prova em uma passada se o ambiente está íntegro.
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
  # A tabela é `partner_institutions`. O nome `institutions` era um chute do
  # esqueleto da etapa 03 e nunca existiu no schema — o check reportava falha
  # com o legado carregado e correto. Pego na etapa 99, na sequência do zero.
  N=$($COMPOSE exec -T postgres-legado psql -U trio -d trio_legado -tAc \
      "SELECT count(*) FROM partner_institutions" 2>/dev/null | tr -d '\r ')
  if [ -n "$N" ] && [ "$N" != "0" ]; then
    line 0 postgres-legado "respondendo · $N instituições"
  elif [ "$N" = "0" ]; then
    line 1 postgres-legado "tabelas existem mas estão VAZIAS — seed do legado falhou"
  else
    line 1 postgres-legado "container de pé, schema do legado ainda não aplicado"
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

# ---------- sync-worker (o pipeline do caminho principal) ----------
# Substituiu o trio redpanda/debezium/cdc-consumer, que este script cobrava
# como se fossem obrigatórios. O CDC foi DESCARTADO na etapa 13 com causa-raiz
# provada (`publish_via_partition_root` não funciona sobre hypertable) e vive
# no profile `cdc-experimento` como artefato da decisão — ausência dele é o
# estado correto, não falha. Ver desafio-2/ADR.md.
if svc_up sync-worker; then
  LAG=$(curl -s localhost:8001/metrics 2>/dev/null | awk '$1=="sync_lag_seconds"{printf "%.1f", $2}')
  if [ -n "$LAG" ]; then
    line 0 sync-worker "respondendo · lag ${LAG}s"
  else
    line 1 sync-worker "container de pé, métricas ainda não disponíveis"
  fi
else
  line 1 sync-worker "container fora do ar — o pipeline não está rodando"
fi

# ---------- ref-sync (legado -> Dictionary) ----------
if svc_up ref-sync; then
  if curl -sf localhost:8002/metrics 2>/dev/null | grep -q refsync_; then
    line 0 ref-sync "respondendo"
  else
    line 1 ref-sync "container de pé, métricas ainda não disponíveis"
  fi
else
  line 1 ref-sync "container fora do ar"
fi

# ---------- api ----------
if svc_up api; then
  if curl -sf localhost:8000/health >/dev/null 2>&1 || curl -sf localhost:8000/ops/volume-now >/dev/null 2>&1; then
    line 0 api "respondendo"
  else
    line 1 api "container de pé, não responde ainda"
  fi
else
  line 1 api "container fora do ar"
fi

# ---------- CDC (experimento descartado — informativo, nunca falha) ----------
if svc_up redpanda || svc_up debezium; then
  echo "  · profile cdc-experimento ativo (artefato da decisão, fora do caminho principal)"
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
  # HTTPS com `-k`: o MinIO serve TLS com certificado autoassinado (gerado para
  # o pgBackRest, que exige S3 sobre TLS). Com `http://` o check falhava mesmo
  # com o container `healthy` — pego na etapa 99.
  if curl -skf https://localhost:9002/minio/health/live >/dev/null 2>&1; then
    line 0 minio "respondendo (TLS)"
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
