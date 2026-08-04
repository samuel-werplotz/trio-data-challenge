#!/usr/bin/env bash
# demo-sync-worker.sh — demonstração ponta a ponta do pipeline TimescaleDB ->
# ClickHouse (PDF § 4.2 A.2 "demonstrável no docker-compose" e A.3 "tratamento
# de mutações, demonstrado na prática").
#
# Roteiro: INSERT -> aparece no ClickHouse -> UPDATE de status -> reflete ->
# mostra as versões convivendo sem FINAL -> OPTIMIZE colapsa -> idempotência.
#
# Usa uma transação sintética própria (source_institution='DEMO-SYNC') e a
# remove no fim. Nunca toca no dataset de 10M.
set -uo pipefail

TS="docker exec trio-timescaledb psql -U trio -d trio_transactions -tAc"
CH="docker exec trio-clickhouse clickhouse-client -u trio --password trio2024 -d trio_analytics -q"
CICLO=${CICLO:-14}   # ciclo do worker é 10s; 14 dá folga para leitura + escrita

titulo() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
limpar() {
  $TS "DELETE FROM _timescaledb_internal._hyper_1_1424_chunk WHERE source_institution='DEMO-SYNC'" >/dev/null 2>&1
  # raw + as 2 MVs. As agregadas contam inserções e não se desfazem ao apagar a
  # raw — sem limpá-las, cada execução da demo inflaria o total dos agregados.
  for t in transactions_raw daily_by_institution status_funnel; do
    $CH "ALTER TABLE $t DELETE WHERE source_institution='DEMO-SYNC' SETTINGS mutations_sync=2" >/dev/null 2>&1
  done
}
trap limpar EXIT   # sai por erro ou Ctrl-C e ainda assim não deixa lixo

titulo "0. Pré-condições"
docker ps --filter "name=trio-sync-worker" --format "{{.Names}} {{.Status}}" | grep -q Up \
  || { echo "sync-worker não está rodando: docker compose --profile core up -d sync-worker"; exit 1; }
echo "sync-worker de pé"
limpar   # resíduo de uma execução anterior interrompida

titulo "1. INSERT no TimescaleDB (origem)"
$TS "INSERT INTO transactions (external_id, amount, currency, status, type,
     source_institution, destination_institution, created_at)
     VALUES (gen_random_uuid(), 4321.00,'BRL','pending','pix','DEMO-SYNC','002', now())" >/dev/null
ID=$($TS "SELECT id FROM transactions WHERE source_institution='DEMO-SYNC' ORDER BY id DESC LIMIT 1" | tr -d '\r\n ')
echo "transação criada: id=$ID status=pending"

titulo "2. Aguardando o ciclo do worker (${CICLO}s)"
sleep "$CICLO"
echo "no ClickHouse:"
$CH "SELECT tx_id, status, amount FROM transactions_raw FINAL WHERE tx_id=$ID FORMAT PrettyCompact"

titulo "3. MUTAÇÃO: pending -> settled na origem"
$TS "UPDATE transactions SET status='settled', settled_at=now() WHERE id=$ID" >/dev/null
echo "UPDATE aplicado no TimescaleDB"

titulo "4. Aguardando o ciclo (${CICLO}s)"
sleep "$CICLO"
echo "o ClickHouse refletiu a mudança:"
$CH "SELECT tx_id, status, settled_at FROM transactions_raw FINAL WHERE tx_id=$ID FORMAT PrettyCompact"

titulo "5. As duas versões convivendo — SEM FINAL"
# É o ponto que a banca costuma perguntar: o ReplacingMergeTree não apaga a
# versão antiga na hora do INSERT. Ele guarda as duas e resolve o desempate na
# leitura (FINAL) ou no merge de fundo, pelo maior _version.
$CH "SELECT tx_id, status, _version FROM transactions_raw WHERE tx_id=$ID ORDER BY _version FORMAT PrettyCompact"
echo "(se aparecer 1 linha só, um merge de fundo já colapsou — rode de novo para ver as 2)"

titulo "6. OPTIMIZE FINAL força o merge"
# settings=1 faz o comando ESPERAR o merge terminar. Sem isso ele retorna assim
# que agenda, e o SELECT seguinte ainda enxerga as 2 partes — o que parece falha
# da demo mas é só assincronismo.
$CH "OPTIMIZE TABLE transactions_raw FINAL SETTINGS alter_sync=2, optimize_throw_if_noop=0" >/dev/null 2>&1
sleep 2
$CH "SELECT count() AS linhas_apos_merge FROM transactions_raw WHERE tx_id=$ID FORMAT PrettyCompact"
echo "(1 = as versões colapsaram na mais recente, que é o que FINAL já mostrava)"

titulo "7. IDEMPOTÊNCIA: reprocessar não duplica"
ANTES=$($CH "SELECT count() FROM (SELECT * FROM transactions_raw FINAL)" | tr -d '\r\n ')
echo "count() FINAL antes:  $ANTES"
# Recuar o watermark força o worker a reler uma janela já processada — é o
# equivalente, neste desenho, a reprocessar do offset 0 no Kafka.
$TS "UPDATE sync_state SET last_updated_at = last_updated_at - interval '1 hour' WHERE source='transactions'" >/dev/null
sleep "$CICLO"
DEPOIS=$($CH "SELECT count() FROM (SELECT * FROM transactions_raw FINAL)" | tr -d '\r\n ')
echo "count() FINAL depois: $DEPOIS"
[ "$ANTES" = "$DEPOIS" ] && echo "OK — idempotente" || { echo "FALHOU: $ANTES != $DEPOIS"; exit 1; }

titulo "8. Métricas do pipeline (:8001)"
curl -s localhost:8001/metrics 2>/dev/null \
  | grep -E "^sync_(last_success_timestamp|lag_seconds|rows_written_total|cycles_total)" \
  || echo "(métricas indisponíveis — worker exposto na 8001?)"

titulo "Fim — removendo a transação de demonstração"
