#!/usr/bin/env bash
# q4-cenario-demo.sh — planta um cenário de duplicata, demonstra a Q4
# detectando, e limpa.
#
# Por que existe: a Q4 devolve **0 linhas** contra o dataset atual, e isso é o
# resultado CORRETO — o gerador não produz duplicata em janela de 5 min (a
# mesma propriedade que faz `/fraud/duplicates` devolver vazio, registrada no
# LOG da etapa 14). Mas "0" numa demonstração ao vivo é indistinguível de query
# quebrada. Este script separa "não achou porque não existe" de "não achou
# porque está errada".
#
# Mesmo padrão de retention-demo.sh e lgpd-erasure-demo.sh: planta, prova,
# limpa e confere.
#
# Uso:  bash desafio-1/scripts/q4-cenario-demo.sh [--cleanup]
set -uo pipefail

PG="docker exec -i trio-timescaledb psql -qtA -U trio -d trio_transactions"
CH="docker exec -i trio-clickhouse clickhouse-client -u trio --password ${CLICKHOUSE_PASSWORD:-trio2024}"

# Conta sintética fora da faixa do seed (1..500.000): a limpeza fica exata e
# nenhuma conta real entra no cenário.
CONTA_ORIGEM=999999901
CONTA_DESTINO=999999902

limpar() {
  $PG -c "DELETE FROM transactions
           WHERE source_account_id = $CONTA_ORIGEM
             AND destination_account_id = $CONTA_DESTINO" >/dev/null 2>&1
  # A raw e as 2 MVs precisam ser limpas separadamente — MV no ClickHouse é
  # gatilho de inserção, não view que recalcula (etapas 12 e 16).
  for T in transactions_raw daily_by_institution status_funnel; do
    $CH -q "ALTER TABLE trio_analytics.$T DELETE
            WHERE source_institution = '998' SETTINGS mutations_sync=2" >/dev/null 2>&1
  done
}

if [ "${1:-}" = "--cleanup" ]; then
  echo "== limpeza =="
  limpar
  echo "  origem: $($PG -c 'SELECT count(*) FROM transactions' | tr -d '\r ') linhas"
  echo "  destino: $($CH -q 'SELECT count() FROM trio_analytics.transactions_raw' | tr -d '\r ') linhas"
  exit 0
fi

echo "=================================================================="
echo " Q4 — detecção de duplicata em janela de 5 minutos"
echo "=================================================================="
echo
echo "[1/5] Estado ANTES: quantas duplicatas a Q4 encontra hoje?"
ANTES=$($PG -c "
  WITH ordenadas AS (
    SELECT id, LAG(created_at) OVER w AS anterior_em, created_at
      FROM transactions
     WHERE created_at >= now() - INTERVAL '7 days'
    WINDOW w AS (PARTITION BY amount, source_account_id, destination_account_id
                 ORDER BY created_at)
  )
  SELECT count(*) FROM ordenadas
   WHERE anterior_em IS NOT NULL AND created_at - anterior_em <= INTERVAL '5 minutes'
" | tr -d '\r ')
echo "      -> $ANTES duplicata(s)."
echo "      Zero é o resultado correto: o gerador não produz duplicata em 5 min."
echo "      É por isso que este cenário existe — para provar que a query detecta."
echo

echo "[2/5] Plantando: 3 cobranças idênticas (R\$ 149,90) com 90s entre elas."
echo "      Cenário real: cliente clica 3x no botão de pagar."
$PG -c "
  INSERT INTO transactions (
    external_id, created_at, updated_at, type, status, amount, currency,
    source_institution, destination_institution,
    source_account_id, destination_account_id, metadata
  )
  SELECT gen_random_uuid(),
         now() - (INTERVAL '90 seconds' * g),
         now() - (INTERVAL '90 seconds' * g),
         'pix', 'settled', 149.90, 'BRL', '998', '998',
         $CONTA_ORIGEM, $CONTA_DESTINO,
         '{\"cenario\":\"q4-demo\",\"origem\":\"clique-duplicado\"}'::jsonb
    FROM generate_series(0, 2) g;" >/dev/null
echo "      -> 3 transações plantadas."
echo

echo "[3/5] Rodando a Q4 (a versão otimizada, com window function):"
echo
$PG -c "\pset border 2" >/dev/null 2>&1
docker exec -i trio-timescaledb psql -U trio -d trio_transactions -c "
  WITH ordenadas AS (
    SELECT id, external_id, amount, created_at, source_account_id,
           LAG(created_at) OVER w AS anterior_em,
           LAG(id)         OVER w AS anterior_id
      FROM transactions
     WHERE created_at >= now() - INTERVAL '7 days'
    WINDOW w AS (PARTITION BY amount, source_account_id, destination_account_id
                 ORDER BY created_at)
  )
  SELECT anterior_id AS id_anterior, id AS id_duplicado, amount AS valor,
         EXTRACT(EPOCH FROM (created_at - anterior_em))::int AS segundos_entre
    FROM ordenadas
   WHERE anterior_em IS NOT NULL
     AND created_at - anterior_em <= INTERVAL '5 minutes'
   ORDER BY created_at DESC;"

DEPOIS=$($PG -c "
  WITH ordenadas AS (
    SELECT id, LAG(created_at) OVER w AS anterior_em, created_at
      FROM transactions
     WHERE created_at >= now() - INTERVAL '7 days'
    WINDOW w AS (PARTITION BY amount, source_account_id, destination_account_id
                 ORDER BY created_at)
  )
  SELECT count(*) FROM ordenadas
   WHERE anterior_em IS NOT NULL AND created_at - anterior_em <= INTERVAL '5 minutes'
" | tr -d '\r ')

echo "[4/5] Resultado: $ANTES -> $DEPOIS duplicata(s) detectada(s)."
echo "      3 cobranças geram 2 pares consecutivos (1->2, 2->3)."
echo "      A janela é entre transações CONSECUTIVAS, por isso 2 e não 3."
echo

echo "[5/5] Limpando o cenário."
limpar
FINAL=$($PG -c "SELECT count(*) FROM transactions" | tr -d '\r ')
FINAL_CH=$($CH -q "SELECT count() FROM trio_analytics.transactions_raw" | tr -d '\r ')
echo "      origem=$FINAL destino=$FINAL_CH"
echo
if [ "$DEPOIS" -gt "$ANTES" ]; then
  echo "OK — a Q4 detecta. O '0' do dataset é propriedade do dado, não defeito."
  exit 0
fi
echo "FALHOU — a Q4 não detectou o cenário plantado."
exit 1
