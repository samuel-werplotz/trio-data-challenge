#!/usr/bin/env bash
# retention-demo.sh — prova que a política de retenção de 90 dias funciona,
# sem apagar um único byte do dataset de 12 meses da demonstração.
#
# O problema que este script resolve: o enunciado pede 12 meses de dado E
# retenção de 90 dias. As duas coisas não cabem juntas — rodar a política sobre
# o dataset real apagaria 9 dos 12 meses. Por isso a política nasce
# `scheduled => false` em 04_caggs_policies.sql, e a prova de que ela funciona
# é feita aqui, sobre dado descartável.
#
# Como: insere linhas num intervalo onde o dataset real não tem NADA (2020),
# criando chunks exclusivamente sintéticos. A política roda pelo mecanismo real
# do TimescaleDB, mas com `drop_after` temporariamente calibrado para que seu
# limite caia em 2021 — alcança 2020, para bem antes de set/2025. Os chunks
# sintéticos somem, o dataset não é tocado, e ao final tudo volta ao estado
# anterior (90 dias, desligada).
#
# Uso: ./desafio-1/scripts/retention-demo.sh   (ou `make demo-retention`)
set -uo pipefail

PSQL="docker compose exec -T timescaledb psql -q -U trio -d trio_transactions"
PSQL_TA="docker compose exec -T timescaledb psql -qtA -U trio -d trio_transactions"

# Marcador das linhas sintéticas: instituição que não existe no dataset real.
# Serve de rede de segurança no cleanup — nada real casa com este filtro.
DEMO_INST='DEMO-RETENTION'
DEMO_EPOCH='2020-01-15'   # 6 anos atrás: fora de qualquer janela real

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

count_tx()     { $PSQL_TA -c "SELECT count(*) FROM transactions"; }
count_demo()   { $PSQL_TA -c "SELECT count(*) FROM transactions WHERE source_institution='$DEMO_INST'"; }
count_chunks() { $PSQL_TA -c "SELECT count(*) FROM timescaledb_information.chunks WHERE hypertable_name='transactions'"; }

# Estado que precisa ser restaurado mesmo se algo falhar no meio.
cleanup() {
  step "CLEANUP — restaurando estado original"
  # Apaga qualquer linha sintética que a retenção não tenha levado.
  $PSQL -c "DELETE FROM transactions WHERE source_institution='$DEMO_INST';" >/dev/null 2>&1
  # Devolve a política ao estado de repouso: 90 dias e DESLIGADA.
  $PSQL -c "SELECT remove_retention_policy('transactions', if_exists => true);" >/dev/null 2>&1
  $PSQL -c "SELECT add_retention_policy('transactions', INTERVAL '90 days', if_not_exists => true);" >/dev/null 2>&1
  $PSQL -c "SELECT alter_job(job_id, scheduled => false)
            FROM timescaledb_information.jobs
            WHERE proc_name='policy_retention' AND hypertable_name='transactions';" >/dev/null 2>&1

  local final scheduled
  final=$(count_tx)
  scheduled=$($PSQL_TA -c "SELECT scheduled FROM timescaledb_information.jobs
                           WHERE proc_name='policy_retention' AND hypertable_name='transactions'")
  echo "  transactions ............ $final linhas"
  echo "  política de retenção .... 90 days, scheduled=$scheduled (esperado: f)"

  if [ "$final" != "$BASELINE" ]; then
    echo "  ERRO: contagem final ($final) difere da inicial ($BASELINE)"
    exit 1
  fi
  echo "  dataset intacto."
}

step "BASELINE"
BASELINE=$(count_tx)
CHUNKS_0=$(count_chunks)
echo "  transactions ............ $BASELINE linhas"
echo "  chunks .................. $CHUNKS_0"
echo "  política de retenção .... criada e DESLIGADA (ver 04_caggs_policies.sql)"

# A partir daqui qualquer saída passa pelo cleanup.
trap cleanup EXIT

step "1. Inserindo linhas sintéticas em 2020 (fora do dataset real)"
# 3 dias distintos → 3 chunks próprios, já que o chunk interval é de 1 dia.
$PSQL -c "
INSERT INTO transactions
    (external_id, amount, currency, status, type,
     source_institution, destination_institution, created_at, updated_at)
SELECT gen_random_uuid(), 100.00, 'BRL', 'settled', 'pix',
       '$DEMO_INST', '$DEMO_INST',
       '$DEMO_EPOCH'::timestamptz + (d || ' days')::interval,
       '$DEMO_EPOCH'::timestamptz + (d || ' days')::interval
FROM generate_series(0, 2) d, generate_series(1, 100) n;" >/dev/null

DEMO_N=$(count_demo)
CHUNKS_1=$(count_chunks)
echo "  linhas sintéticas ....... $DEMO_N"
echo "  chunks .................. $CHUNKS_1 (+$((CHUNKS_1 - CHUNKS_0)) novos, só de 2020)"

$PSQL -c "
SELECT chunk_name, range_start::date AS inicio, range_end::date AS fim
FROM timescaledb_information.chunks
WHERE hypertable_name='transactions' AND range_end < '2021-01-01'
ORDER BY range_start;"

step "2. Ligando a retenção — calibrada para alcançar só 2020"
# `drop_after` é dimensionado para cair entre 2020 e o início do dataset real
# (set/2025). Assim a política roda DE VERDADE, no mecanismo real do
# TimescaleDB, mas o alcance dela para antes do dado que queremos preservar.
DROP_AFTER=$($PSQL_TA -c "SELECT (date_trunc('day', now()) - '2021-01-01'::timestamptz)::text")
echo "  drop_after .............. $DROP_AFTER  (limite cai em 2021-01-01)"

$PSQL -c "SELECT remove_retention_policy('transactions', if_exists => true);" >/dev/null
$PSQL -c "SELECT add_retention_policy('transactions', INTERVAL '$DROP_AFTER');" >/dev/null
$PSQL -c "SELECT alter_job(job_id, scheduled => true)
          FROM timescaledb_information.jobs
          WHERE proc_name='policy_retention' AND hypertable_name='transactions';" >/dev/null

step "3. Executando a política"
JOB_ID=$($PSQL_TA -c "SELECT job_id FROM timescaledb_information.jobs
                      WHERE proc_name='policy_retention' AND hypertable_name='transactions'")
echo "  job_id .................. $JOB_ID"
# `run_job` executa o job agora, no mesmo caminho de código do agendador.
$PSQL -c "CALL run_job($JOB_ID);"

step "4. Resultado"
AFTER_DEMO=$(count_demo)
AFTER_TX=$(count_tx)
CHUNKS_2=$(count_chunks)
REMAIN_2020=$($PSQL_TA -c "SELECT count(*) FROM timescaledb_information.chunks
                           WHERE hypertable_name='transactions' AND range_end < '2021-01-01'")

echo "  chunks de 2020 .......... $REMAIN_2020 (era $((CHUNKS_1 - CHUNKS_0)))"
echo "  linhas sintéticas ....... $AFTER_DEMO (era $DEMO_N)"
echo "  chunks totais ........... $CHUNKS_2 (era $CHUNKS_1)"
echo "  transactions ............ $AFTER_TX (baseline $BASELINE)"

if [ "$REMAIN_2020" = "0" ] && [ "$AFTER_DEMO" = "0" ] && [ "$AFTER_TX" = "$BASELINE" ]; then
  echo
  echo "  OK: a retenção removeu os chunks sintéticos e não tocou no dataset."
else
  echo
  echo "  FALHA: retenção não se comportou como esperado."
  exit 1
fi
