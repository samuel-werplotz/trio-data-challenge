#!/usr/bin/env bash
# demo-mutation.sh — demonstração de mutação CDC ponta a ponta (
# Demonstração de mutação). O passo 7 é o mais valioso: mostra 2 linhas
# físicas para o mesmo tx_id ANTES do merge, prova que se entende o
# mecanismo do ReplacingMergeTree em vez de ter copiado uma receita.
set -uo pipefail

PG="docker compose exec -T timescaledb psql -q -U trio -d trio_transactions"
PG_TA="docker compose exec -T timescaledb psql -qtA -U trio -d trio_transactions"
CH="docker compose exec -T clickhouse clickhouse-client --user trio --password trio2024"

step() { printf '\n\033[1m[%s] %s\033[0m\n' "$1" "$2"; }

# Limpa qualquer resíduo de execução anterior do próprio demo antes de
# começar — a instituição sintética 'DEMO-CDC' nunca existe no dataset real,
# então filtrar por ela é seguro (não risca dado do seed).
docker compose exec -T timescaledb psql -q -U trio -d trio_transactions -c \
  "DELETE FROM transactions WHERE source_institution = 'DEMO-CDC';" >/dev/null 2>&1

step 1 "INSERT de transação 'pending' no TimescaleDB"
EXT_ID=$($PG_TA -c "
INSERT INTO transactions (external_id, amount, currency, status, type,
                          source_institution, destination_institution, created_at, updated_at)
VALUES (gen_random_uuid(), 777.00, 'BRL', 'pending', 'pix', 'DEMO-CDC', 'DEMO-CDC', now(), now())
RETURNING external_id;")
TX_ID=$($PG_TA -c "SELECT id FROM transactions WHERE external_id = '$EXT_ID'")
echo "  external_id = $EXT_ID"
echo "  tx_id (id)  = $TX_ID"

step 2 "aguardando 3s (propagação via CDC)"
sleep 3

step 3 "SELECT no ClickHouse — esperado: pending"
$CH -q "SELECT tx_id, status FROM trio_analytics.transactions_raw WHERE tx_id = $TX_ID"

step 4 "UPDATE para 'settled' no TimescaleDB"
$PG -c "UPDATE transactions SET status = 'settled', settled_at = now(), updated_at = now() WHERE id = $TX_ID;"

step 5 "aguardando 3s (propagação via CDC)"
sleep 3

step 6 "SELECT ... FINAL — esperado: settled"
$CH -q "SELECT tx_id, status FROM trio_analytics.transactions_raw FINAL WHERE tx_id = $TX_ID"

step 7 "SELECT SEM FINAL — o estado intermediário que explica o mecanismo"
echo "  Duas linhas físicas coexistem até o merge assíncrono: o INSERT original"
echo "  ('pending') e o novo estado ('settled') gerado pelo UPDATE. O"
echo "  ReplacingMergeTree não sobrescreve em disco na hora — ele marca a mais"
echo "  recente (_version = updated_at em ms) como vencedora só na leitura com"
echo "  FINAL ou quando o merge físico acontecer em background."
N_SEM_FINAL=$($CH -q "SELECT count() FROM trio_analytics.transactions_raw WHERE tx_id = $TX_ID")
$CH -q "SELECT tx_id, status, _version FROM trio_analytics.transactions_raw WHERE tx_id = $TX_ID ORDER BY _version"
echo "  linhas sem FINAL: $N_SEM_FINAL (esperado: 2)"

step 8 "OPTIMIZE TABLE ... FINAL (força o merge agora, não espera o background)"
$CH -q "OPTIMIZE TABLE trio_analytics.transactions_raw FINAL"

step 9 "SELECT sem FINAL, pós-OPTIMIZE — esperado: 1 linha"
N_POS_OPTIMIZE=$($CH -q "SELECT count() FROM trio_analytics.transactions_raw WHERE tx_id = $TX_ID")
$CH -q "SELECT tx_id, status FROM trio_analytics.transactions_raw WHERE tx_id = $TX_ID"
echo "  linhas pós-OPTIMIZE: $N_POS_OPTIMIZE (esperado: 1)"

step 10 "cleanup — removendo a transação sintética dos dois lados"
$PG -c "DELETE FROM transactions WHERE id = $TX_ID;" >/dev/null
$CH -q "ALTER TABLE trio_analytics.transactions_raw DELETE WHERE tx_id = $TX_ID" >/dev/null 2>&1

echo
if [ "$N_SEM_FINAL" = "2" ] && [ "$N_POS_OPTIMIZE" = "1" ]; then
  echo "OK: mecanismo de dedup do ReplacingMergeTree demonstrado ponta a ponta."
else
  echo "FALHA: esperava 2 linhas antes do OPTIMIZE e 1 depois; achei $N_SEM_FINAL e $N_POS_OPTIMIZE."
  exit 1
fi
