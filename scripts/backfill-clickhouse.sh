#!/usr/bin/env bash
# backfill-clickhouse.sh — backfill dos 10M de transactions do TimescaleDB
# para o ClickHouse (S05 § Backfill inicial), direto via postgresql(), sem
# passar pelo Kafka. Roda em blocos mensais (12 chamadas), não uma inserção
# única, para não estourar memória e para poder retomar de onde parou se
# um mês falhar. Idempotente por mês: ReplacingMergeTree deduplica por
# _version se um bloco for reexecutado.
#
# ARMADILHA REAL (não teórica) descoberta ao rodar isto pela primeira vez:
# as MVs (mv_daily_by_institution, mv_status_funnel) já existem desde a
# etapa 11 e são GATILHO DE INSERÇÃO — elas capturam sozinhas cada bloco
# mensal inserido em transactions_raw abaixo. Rodar o INSERT SELECT de
# backfill das MVs *depois* disso duplica tudo (visto na prática: 20M em
# vez de 10M agregados). Por isso este script SÓ faz o INSERT SELECT das
# MVs se elas estiverem vazias — se a MV já capturou tudo em tempo real
# durante o backfill do raw, o INSERT SELECT manual é desnecessário e
# destrutivo. Ver 99-validacao-final.md para o relato completo.
set -euo pipefail

CH="docker compose exec -T clickhouse clickhouse-client --user trio --password trio2024"

# 12 meses do dataset real (set/2025 a ago/2026) — não os "ago/2025 a jul/2026"
# do exemplo ilustrativo de S05, que usava datas genéricas.
MESES=(
  2025-09-01 2025-10-01 2025-11-01 2025-12-01
  2026-01-01 2026-02-01 2026-03-01 2026-04-01
  2026-05-01 2026-06-01 2026-07-01 2026-08-01
  2026-09-01  # limite superior do último bloco
)

echo "== Backfill transactions_raw (12 blocos mensais) =="
for i in $(seq 0 11); do
  ini="${MESES[$i]}"
  fim="${MESES[$((i+1))]}"
  echo -n "  $ini .. $fim ... "
  $CH -q "
    INSERT INTO trio_analytics.transactions_raw
    SELECT external_id, id, created_at, settled_at, type, status, amount,
           currency, source_institution, destination_institution,
           source_account_id, destination_account_id, metadata,
           toUnixTimestamp64Milli(updated_at) AS _version, 0, now()
    FROM postgresql('timescaledb:5432','trio_transactions','transactions',
                    'trio','trio2024')
    WHERE created_at >= '$ini' AND created_at < '$fim';"
  n=$($CH -q "SELECT count(*) FROM trio_analytics.transactions_raw WHERE created_at >= '$ini' AND created_at < '$fim'")
  echo "$n linhas"
done

echo
echo "== Conferindo total =="
TOTAL=$($CH -q "SELECT count(*) FROM trio_analytics.transactions_raw")
TOTAL_FINAL=$($CH -q "SELECT count() FROM trio_analytics.transactions_raw FINAL")
echo "  count(*) ........ $TOTAL"
echo "  count() FINAL .... $TOTAL_FINAL (dedup — deve bater com count(*))"

echo
echo "== Populando as 2 MVs (INSERT SELECT) =="
echo "   Só roda se a MV ainda não capturou nada sozinha (ver comentário no topo do script)."

# MV já ativa desde a etapa 11: se este backfill já rodou uma vez nesta
# sessão, a MV capturou tudo em tempo real e a tabela já não está vazia —
# rodar o INSERT SELECT de novo duplicaria.
N_DAILY_ANTES=$($CH -q "SELECT count() FROM trio_analytics.daily_by_institution")
if [ "$N_DAILY_ANTES" = "0" ]; then
  $CH -q "
  INSERT INTO trio_analytics.daily_by_institution
  SELECT toDate(created_at), source_institution, type,
         countState(), sumState(amount), avgState(amount),
         quantileState(0.95)(amount), quantileState(0.99)(amount),
         countIfState(status='settled'), countIfState(status='failed'),
         avgState(settlement_seconds)
  FROM trio_analytics.transactions_raw
  GROUP BY 1,2,3;"
  echo "  daily_by_institution: populada via INSERT SELECT (estava vazia)"
else
  echo "  daily_by_institution: já tinha $N_DAILY_ANTES linhas (capturado pela MV durante o backfill do raw) — INSERT SELECT pulado"
fi

N_FUNNEL_ANTES=$($CH -q "SELECT count() FROM trio_analytics.status_funnel")
if [ "$N_FUNNEL_ANTES" = "0" ]; then
  $CH -q "
  INSERT INTO trio_analytics.status_funnel
  SELECT toStartOfHour(created_at) AS hour, type, source_institution, status,
         countState(),
         avgState(settlement_seconds),
         quantileState(0.50)(settlement_seconds),
         quantileState(0.95)(settlement_seconds)
  FROM trio_analytics.transactions_raw
  GROUP BY 1,2,3,4;"
  echo "  status_funnel: populada via INSERT SELECT (estava vazia)"
else
  echo "  status_funnel: já tinha $N_FUNNEL_ANTES linhas (capturado pela MV durante o backfill do raw) — INSERT SELECT pulado"
fi

N_DAILY=$($CH -q "
SELECT sum(cnt) FROM (
  SELECT day, source_institution, type, countMerge(tx_count) AS cnt
  FROM trio_analytics.daily_by_institution GROUP BY day, source_institution, type)")
N_FUNNEL=$($CH -q "
SELECT sum(cnt) FROM (
  SELECT hour, type, source_institution, status, countMerge(cnt) AS cnt
  FROM trio_analytics.status_funnel GROUP BY hour, type, source_institution, status)")
echo "  daily_by_institution: countMerge total = $N_DAILY (deve bater com $TOTAL)"
echo "  status_funnel: countMerge total = $N_FUNNEL (deve bater com $TOTAL)"

echo
echo "Concluído."
