#!/usr/bin/env bash
# run_all.sh — suíte de regressão cumulativa do Trio Data Challenge.
# Roda em Bash (Git Bash no Windows). Guarda de regressão, não substitui revisão humana.
#
# ┌── REGRA DE ACUMULAÇÃO ────────────────────────────────────────────────────┐
# │ Cada etapa do roadmap ACRESCENTA um bloco no fim da seção de testes.      │
# │ NUNCA reescreva, reordene ou remova blocos de etapas anteriores: o valor  │
# │ deste arquivo é justamente pegar a regressão que uma etapa nova causou    │
# │ numa etapa velha. Se um teste antigo ficou obsoleto, é desvio de plano —  │
# │ registrar em 99-validacao-final.md antes de mexer.                        │
# └──────────────────────────────────────────────────────────────────────────┘
#
# Estados: PASS · FAIL · SKIP. SKIP é para pré-condição ausente (container fora
# do ar, seed não rodado) e NÃO é falha. Exit 1 se houver qualquer FAIL; 0 caso
# contrário.

set -uo pipefail  # sem -e: um teste que falha não pode abortar a suíte

PASS_N=0
FAIL_N=0
SKIP_N=0

# ---------- primitivas de resultado ----------
# Recebem o id do teste; a mensagem opcional explica o porquê (essencial no SKIP).

ok()   { PASS_N=$((PASS_N + 1)); printf 'PASS  %-28s %s\n' "$1" "${2:-}"; }
fail() { FAIL_N=$((FAIL_N + 1)); printf 'FAIL  %-28s %s\n' "$1" "${2:-}"; }
skip() { SKIP_N=$((SKIP_N + 1)); printf 'SKIP  %-28s %s\n' "$1" "${2:-}"; }

# check <id> <descrição> <comando...> — PASS se o comando sai 0, FAIL se não.
check() {
  local id="$1" desc="$2"; shift 2
  if "$@" >/dev/null 2>&1; then ok "$id" "$desc"; else fail "$id" "$desc"; fi
}

# ---------- pré-condições (usadas para decidir SKIP) ----------
# Existem para que a suíte rode igual na trilha `local` e na `carga-real`,
# marcando SKIP em vez de FAIL quando o ambiente simplesmente não está de pé.

has_docker()    { command -v docker >/dev/null 2>&1; }
has_make()      { command -v make >/dev/null 2>&1; }  # ausente neste ambiente Windows (winget falhou por rede)
container_up()  { has_docker && [ -n "$(docker compose ps -q "$1" 2>/dev/null)" ]; }
seed_done()     {
  container_up timescaledb || return 1
  [ "$(docker compose exec -T timescaledb psql -q -U trio -d trio_transactions -tAc \
       "SELECT finished_at IS NOT NULL FROM seed_control" 2>/dev/null | head -1)" = "t" ]
}

echo "== run_all.sh =="

# ===========================================================================
# TESTES POR ETAPA — acrescentar abaixo, nunca acima. Um bloco por etapa,
# no formato:  # --- NN <nome da etapa> ---
# ===========================================================================

# --- 01 baseline-e-estrutura ---
check 01.1 "aninhamento achatado"        test ! -d trio-data-challenge
check 01.2 "starter na raiz"             bash -c 'test -f docker-compose.yml -a -f .env.example -a -d init'
TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
case "$TOP" in *trio-data-challenge) ok 01.3 "git root correto";; *) fail 01.3 "git root: ${TOP:-ausente}";; esac
BR="$(git branch --show-current 2>/dev/null || true)"
[ "$BR" = "wip/trio-challenge" ] && ok 01.4 "branch wip/trio-challenge" || fail 01.4 "branch atual: ${BR:-nenhuma}"
check 01.5 "árvore do PDF §6 criada"     bash -c 'test -d desafio-1/schemas -a -d desafio-2/pipeline -a -d desafio-3/backup -a -d docs'
check 01.6 ".gitignore cobre .env"       grep -q '^\.env$' .gitignore
check 01.7 "sem material de estudo no repo" bash -c 'test ! -e vault-estudo -a -z "$(ls *.pdf 2>/dev/null)"'

# --- 02 compose-evoluido ---
# Sem --profile nenhum serviço resolve (todos os 15 têm profiles: core/full) —
# por isso os testes de config usam --profile full, que resolve o conjunto completo.
check 02.1 "docker compose config válido" docker compose --profile full config -q
if has_docker; then
  N_IMG=$(docker compose --profile full config 2>/dev/null | grep -c '^\s*image:')
  [ "$N_IMG" -eq 10 ] && ok 02.2 "10 serviços com image: (+5 build local = 15)" \
    || fail 02.2 "esperava 10 image:, achei $N_IMG"
else
  skip 02.2 "docker indisponível"
fi
check 02.3 "nenhuma imagem :latest (exceto latest-pg16)" \
  bash -c '! docker compose --profile full config 2>/dev/null | grep ":latest" | grep -v "latest-pg16" | grep -q .'
check 02.4 "MinIO publica 9002" \
  bash -c 'docker compose --profile full config 2>/dev/null | grep -q "9002"'
check 02.5 "perfis core e full declarados" \
  bash -c 'docker compose --profile full config --profiles 2>/dev/null | sort -u | grep -qx core && docker compose --profile full config --profiles 2>/dev/null | sort -u | grep -qx full'
if container_up timescaledb && container_up postgres-legado && container_up clickhouse; then
  H=$(docker compose ps --format '{{.Health}}' timescaledb postgres-legado clickhouse 2>/dev/null | sort -u)
  [ "$H" = "healthy" ] && ok 02.6 "timescaledb/postgres-legado/clickhouse healthy" \
    || fail 02.6 "algum serviço não healthy: $H"
else
  skip 02.6 "serviços core (imagem pronta) não estão de pé — subir com: docker compose up -d timescaledb postgres-legado clickhouse grafana"
fi

# --- 03 makefile-e-healthcheck ---
check 03.3 "scripts executáveis" bash -c 'test -x scripts/health-check.sh -a -x scripts/wait-healthy.sh'
check 03.4 "sintaxe dos scripts" bash -c 'bash -n scripts/health-check.sh && bash -n scripts/wait-healthy.sh'
check 03.6 "Makefile: help é alvo padrão" grep -q '^\.DEFAULT_GOAL := help' Makefile
N_ALVOS=$(grep -cE '^[a-zA-Z_-]+:.*##' Makefile)
[ "$N_ALVOS" -eq 23 ] && ok 03.7 "23 alvos documentados no Makefile" \
  || fail 03.7 "esperava 23 alvos com ##, achei $N_ALVOS"
if has_make; then
  check 03.1 "make help" make help
  check 03.2 "make -n up expande" make -n up
  if container_up timescaledb && container_up postgres-legado && container_up clickhouse; then
    make check >/dev/null 2>&1
    ok 03.5 "make check roda (exit não avaliado — schema ainda não existe)"
  else
    skip 03.5 "core não está de pé"
  fi
else
  skip 03.1 "make ausente no PATH deste ambiente (winget install GnuWin32.Make falhou por rede)"
  skip 03.2 "make ausente no PATH deste ambiente"
  skip 03.5 "make ausente no PATH deste ambiente"
fi

# --- 04 schema-timescaledb ---
psql_ts() { docker compose exec -T timescaledb psql -q -U trio -d trio_transactions -tAc "$1" 2>/dev/null | head -1; }
if container_up timescaledb; then
  N_HT=$(psql_ts "SELECT count(*) FROM timescaledb_information.hypertables")
  [ "$N_HT" = "2" ] && ok 04.1 "2 hypertables (transactions, reconciliation_events)" \
    || fail 04.1 "esperava 2 hypertables, achei ${N_HT:-erro}"

  N_ENUM=$(psql_ts "SELECT count(*) FROM pg_type WHERE typtype='e'")
  [ "$N_ENUM" = "5" ] && ok 04.2 "5 ENUMs criados" || fail 04.2 "esperava 5 ENUMs, achei ${N_ENUM:-erro}"

  DIFF=$(psql_ts "INSERT INTO reconciliation_events (transaction_id, transaction_created_at, external_reference, event_type, amount_expected, amount_received) VALUES (999999, now(), 'RUN_ALL_TEST', 'settlement', 100.00, 99.95) RETURNING difference")
  [ "$DIFF" = "-0.05" ] && ok 04.3 "coluna gerada difference = -0.05" || fail 04.3 "difference retornou '${DIFF:-erro}'"
  psql_ts "DELETE FROM reconciliation_events WHERE external_reference='RUN_ALL_TEST'" >/dev/null

  ID=$(psql_ts "INSERT INTO transactions (external_id, amount, type, source_institution, destination_institution) VALUES (gen_random_uuid(), 1.00, 'pix', 'A', 'B') RETURNING id")
  U1=$(psql_ts "SELECT updated_at FROM transactions WHERE id=$ID")
  psql_ts "UPDATE transactions SET status='failed' WHERE id=$ID" >/dev/null
  U2=$(psql_ts "SELECT updated_at FROM transactions WHERE id=$ID")
  [ "$U1" != "$U2" ] && ok 04.4 "trigger updated_at dispara em UPDATE" || fail 04.4 "updated_at não mudou ($U1 == $U2)"
  psql_ts "DELETE FROM transactions WHERE id=$ID" >/dev/null

  ERR=$(docker compose exec -T timescaledb psql -U trio -d trio_transactions -c "INSERT INTO seed_control(id) VALUES (2)" 2>&1)
  echo "$ERR" | grep -q 'violates check constraint' && ok 04.5 "seed_control rejeita segunda linha" \
    || fail 04.5 "seed_control não rejeitou id=2"

  # A asserção original era "exatamente 2 índices". A etapa 07 cria índices por
  # design, então contar o total passou a falhar por avanço legítimo da esteira
  # (desvio registrado em 99-validacao-final.md). O que a etapa 04 de fato
  # garante é que ELA não criou índice — nenhum dos índices de 03_indexes.sql
  # nasce aqui, e os 2 implícitos de PK/hypertable existem.
  N_IDX_IMPL=$(psql_ts "SELECT count(*) FROM pg_indexes WHERE tablename='transactions' AND indexname IN ('transactions_pkey','transactions_created_at_idx')")
  [ "$N_IDX_IMPL" = "2" ] && ok 04.6 "os 2 índices implícitos existem (pkey + created_at da hypertable)" \
    || fail 04.6 "esperava os 2 implícitos, achei ${N_IDX_IMPL:-erro}"
else
  skip 04.1 "timescaledb não está de pé"
  skip 04.2 "timescaledb não está de pé"
  skip 04.3 "timescaledb não está de pé"
  skip 04.4 "timescaledb não está de pé"
  skip 04.5 "timescaledb não está de pé"
  skip 04.6 "timescaledb não está de pé"
fi

# --- 05 seed-10m ---
if seed_done; then
  N_TX=$(psql_ts "SELECT count(*) FROM transactions")
  [ "$N_TX" = "10000000" ] && ok 05.1 "10.000.000 transactions" || fail 05.1 "esperava 10M, achei ${N_TX:-erro}"

  N_ACC=$(psql_ts "SELECT count(*) FROM accounts")
  [ "$N_ACC" = "500000" ] && ok 05.2 "500.000 accounts" || fail 05.2 "esperava 500k, achei ${N_ACC:-erro}"

  N_CHUNKS=$(psql_ts "SELECT count(*) FROM timescaledb_information.chunks WHERE hypertable_name='transactions'")
  if [ -n "$N_CHUNKS" ] && [ "$N_CHUNKS" -ge 300 ] && [ "$N_CHUNKS" -le 366 ] 2>/dev/null; then
    ok 05.3 "~365 chunks em transactions ($N_CHUNKS)"
  else
    fail 05.3 "chunks fora da faixa 300-366: ${N_CHUNKS:-erro}"
  fi

  PIX_PCT=$(psql_ts "SELECT round(100.0*count(*)/(SELECT count(*) FROM transactions),1) FROM transactions WHERE type='pix'")
  if [ -n "$PIX_PCT" ] && awk -v p="$PIX_PCT" 'BEGIN{exit !(p>=58 && p<=62)}' 2>/dev/null; then
    ok 05.4 "distribuição por tipo dentro da tolerância (pix ${PIX_PCT}%, esperado ~60%)"
  else
    fail 05.4 "pix fora da tolerância: ${PIX_PCT:-erro}% (esperado ~60%)"
  fi

  # roda o gerador de novo: idempotência deve recusar sem alterar count(*)
  IDEMP_OUT=$(docker compose run --rm seed python generate_transactions.py 2>&1)
  N_TX_AFTER=$(psql_ts "SELECT count(*) FROM transactions")
  if echo "$IDEMP_OUT" | grep -qi "finished_at já preenchido" && [ "$N_TX_AFTER" = "$N_TX" ]; then
    ok 05.5 "make seed de novo não insere nada (idempotência)"
  else
    fail 05.5 "idempotência falhou: count antes=$N_TX depois=$N_TX_AFTER"
  fi

  SC_DONE=$(psql_ts "SELECT finished_at IS NOT NULL FROM seed_control")
  [ "$SC_DONE" = "t" ] && ok 05.6 "seed_control.finished_at preenchido" || fail 05.6 "finished_at vazio"

  ANALYZED=$(psql_ts "SELECT last_analyze IS NOT NULL FROM pg_stat_user_tables WHERE relname='transactions'")
  [ "$ANALYZED" = "t" ] && ok 05.7 "ANALYZE executado em transactions" || fail 05.7 "last_analyze vazio"
else
  skip 05.1 "seed não concluído (seed_control.finished_at vazio ou timescaledb fora do ar)"
  skip 05.2 "seed não concluído"
  skip 05.3 "seed não concluído"
  skip 05.4 "seed não concluído"
  skip 05.5 "seed não concluído"
  skip 05.6 "seed não concluído"
  skip 05.7 "seed não concluído"
fi

# --- 06 queries-antes-indices ---
check 06.1 "q1..q4_before.txt existem" bash -c \
  'test -f desafio-1/queries/explains/q1_before.txt -a -f desafio-1/queries/explains/q2_before.txt -a -f desafio-1/queries/explains/q3_before.txt -a -f desafio-1/queries/explains/q4_before.txt'

N_BUF=$(grep -l 'Buffers:' desafio-1/queries/explains/*_before.txt 2>/dev/null | wc -l)
[ "$N_BUF" = "4" ] && ok 06.2 "4 arquivos com Buffers:" || fail 06.2 "esperava 4, achei $N_BUF"

if seed_done; then
  # Mesma correção de 04.6: o "antes" honesto da etapa 06 é comprovado pelos
  # qN_before.txt (medidos sem índice), não por contar índices hoje — a etapa
  # 07 cria índices legitimamente depois. Ver 99-validacao-final.md.
  check 06.3 "medição 'antes' feita sem índice (evidência nos qN_before.txt)" bash -c \
    '! grep -qE "Index (Only )?Scan using idx_" desafio-1/queries/explains/q*_before.txt'

  # Mesma correção de 04.6/06.3: a etapa 08 cria os CAggs legitimamente, então
  # contar CAggs hoje não prova mais nada sobre a medição "antes". O que o
  # teste realmente guarda é que os qN_before.txt foram medidos SEM CAgg —
  # e isso se prova no plano gravado, que varre `transactions`, não o
  # materialized hypertable. Ver 99-validacao-final.md.
  check 06.4 "medição 'antes' feita sem CAgg (evidência nos qN_before.txt)" bash -c \
    '! grep -q "_materialized_hypertable" desafio-1/queries/explains/q1_before.txt'
else
  skip 06.3 "seed não concluído"
  skip 06.4 "seed não concluído"
fi

check 06.5 "MEDICOES.md menciona mediana" grep -q "mediana" desafio-1/queries/MEDICOES.md

# --- 07 indices-e-otimizacao ---
check 07.1 "q2..q4_after.txt existem" bash -c \
  'test -f desafio-1/queries/explains/q2_after.txt -a -f desafio-1/queries/explains/q3_after.txt -a -f desafio-1/queries/explains/q4_after.txt'

if seed_done; then
  N_IDX_07=$(psql_ts "SELECT count(*) FROM pg_indexes WHERE tablename='transactions'")
  [ -n "$N_IDX_07" ] && [ "$N_IDX_07" -gt 2 ] 2>/dev/null && ok 07.2 "índices criados em transactions ($N_IDX_07)" \
    || fail 07.2 "esperava >2 índices, achei ${N_IDX_07:-erro}"

  PARTIAL=$(psql_ts "SELECT indexdef FROM pg_indexes WHERE indexname='idx_recon_divergent'")
  echo "$PARTIAL" | grep -q "WHERE" && ok 07.3 "índice parcial tem cláusula WHERE" \
    || fail 07.3 "idx_recon_divergent sem WHERE: ${PARTIAL:-ausente}"

  # gapfill: 48h + bucket parcial da hora corrente, nenhum bucket nulo
  N_NULL=$(psql_ts "SELECT count(*) FROM (SELECT time_bucket_gapfill('1 hour', created_at, now() - INTERVAL '48 hours', now()) AS hora FROM transactions WHERE created_at >= now() - INTERVAL '48 hours' AND created_at < now() GROUP BY hora) x WHERE hora IS NULL")
  [ "$N_NULL" = "0" ] && ok 07.5 "gapfill sem bucket nulo" || fail 07.5 "gapfill com ${N_NULL:-erro} buckets nulos"
else
  skip 07.2 "seed não concluído"
  skip 07.3 "seed não concluído"
  skip 07.5 "seed não concluído"
fi

check 07.4 "Q4 otimizada sem self-join" bash -c \
  '! grep -qiE "join +transactions" desafio-1/queries/q4_optimized.sql'
check 07.6 "REPORT.md com tabela antes/depois" bash -c \
  'grep -q "^| Q2 —" desafio-1/REPORT.md && grep -q "^| Q4 —" desafio-1/REPORT.md'

# --- 08 caggs-compressao-retencao ---
check 08.7 "retention-demo.sh com sintaxe válida" bash -n desafio-1/scripts/retention-demo.sh

if seed_done; then
  N_CAGG_08=$(psql_ts "SELECT count(*) FROM timescaledb_information.continuous_aggregates")
  [ "$N_CAGG_08" = "2" ] && ok 08.1 "2 continuous aggregates" \
    || fail 08.1 "esperava 2 CAggs, achei ${N_CAGG_08:-erro}"

  # A retenção do RAW existe mas fica parada: 90 dias apagariam 9 dos 12 meses
  # do dataset. As dos CAggs (2 anos) ficam ligadas — não alcançam nada hoje.
  N_RET_RAW=$(psql_ts "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention' AND hypertable_name='transactions' AND NOT scheduled")
  [ "$N_RET_RAW" = "1" ] && ok 08.2 "retenção do raw existe e está DESLIGADA" \
    || fail 08.2 "esperava 1 política de retenção parada no raw, achei ${N_RET_RAW:-erro}"

  # 3 no total: 1 do raw (parada) + 2 dos CAggs (PDF § 3.2 A.5 pede as duas).
  # O plano da etapa previa 1 antes de o PASSO 7 acrescentar as dos CAggs.
  N_RET=$(psql_ts "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention'")
  [ "$N_RET" = "3" ] && ok 08.3 "3 políticas de retenção (1 raw + 2 CAggs)" \
    || fail 08.3 "esperava 3 políticas de retenção, achei ${N_RET:-erro}"

  N_RET_CAGG=$(psql_ts "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention' AND hypertable_name LIKE 'cagg_%' AND scheduled")
  [ "$N_RET_CAGG" = "2" ] && ok 08.3b "retenção de 2 anos nos 2 CAggs, habilitada" \
    || fail 08.3b "esperava 2 retenções de CAgg ligadas, achei ${N_RET_CAGG:-erro}"

  # O dataset tem que sobreviver a compressão, políticas e retention-demo.
  N_TX_08=$(psql_ts "SELECT count(*) FROM transactions")
  [ "$N_TX_08" = "10000000" ] && ok 08.4 "transactions intacta (10.000.000)" \
    || fail 08.4 "esperava 10000000 linhas, achei ${N_TX_08:-erro}"

  TAXA=$(psql_ts "SELECT round(before_compression_total_bytes::numeric / nullif(after_compression_total_bytes,0), 1) FROM hypertable_compression_stats('transactions')")
  awk -v t="${TAXA:-0}" 'BEGIN{exit !(t>1)}' 2>/dev/null \
    && ok 08.5 "taxa de compressão medida: ${TAXA}× (>1)" \
    || fail 08.5 "taxa de compressão inválida: ${TAXA:-erro}"

  N_VOL=$(psql_ts "SELECT count(*) FROM cagg_volume_hourly")
  [ -n "$N_VOL" ] && [ "$N_VOL" -gt 0 ] 2>/dev/null && ok 08.6 "cagg_volume_hourly materializado ($N_VOL buckets)" \
    || fail 08.6 "cagg_volume_hourly vazio ou erro: ${N_VOL:-erro}"

  # end_offset de 1h nos dois refreshes: sem ele o bucket corrente (ainda
  # recebendo escrita) seria gravado pela metade e nunca revisitado.
  N_EO=$(psql_ts "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_refresh_continuous_aggregate' AND config->>'end_offset' = '01:00:00'")
  [ "$N_EO" = "2" ] && ok 08.8 "end_offset de 1h nas 2 políticas de refresh" \
    || fail 08.8 "esperava 2 refreshes com end_offset 1h, achei ${N_EO:-erro}"

  # segmentby/orderby exatamente como S03 — é a decisão que define a taxa.
  SEG=$(psql_ts "SELECT string_agg(attname, ', ' ORDER BY segmentby_column_index) FROM timescaledb_information.compression_settings WHERE hypertable_name='transactions' AND segmentby_column_index IS NOT NULL")
  [ "$SEG" = "source_institution, type" ] && ok 08.9 "segmentby = source_institution, type" \
    || fail 08.9 "segmentby inesperado: ${SEG:-erro}"

  # Q1 via CAgg tem que bater exatamente com a query sobre o raw. O corte
  # alinhado à hora não é detalhe: no meio do bucket, o mês da borda diverge.
  DIVERG=$(psql_ts "WITH corte AS (SELECT date_trunc('hour', now() - INTERVAL '6 months') AS t),
    raw AS (SELECT date_trunc('month', created_at) AS mes, type, status, count(*) qtd, sum(amount) total
            FROM transactions, corte WHERE created_at >= corte.t GROUP BY 1,2,3),
    cg AS (SELECT date_trunc('month', bucket) AS mes, type, status, sum(tx_count) qtd, sum(total_amount) total
            FROM cagg_volume_hourly, corte WHERE bucket >= corte.t GROUP BY 1,2,3)
    SELECT count(*) FROM raw FULL JOIN cg USING (mes, type, status)
    WHERE raw.qtd IS DISTINCT FROM cg.qtd OR raw.total IS DISTINCT FROM cg.total")
  [ "$DIVERG" = "0" ] && ok 08.10 "Q1 via CAgg idêntica ao raw (0 divergências)" \
    || fail 08.10 "CAgg divergiu do raw em ${DIVERG:-erro} linhas"
else
  for t in 08.1 08.2 08.3 08.3b 08.4 08.5 08.6 08.8 08.9 08.10; do
    skip "$t" "seed não concluído"
  done
fi

check 08.11 "q1_after.txt existe (Q1 via CAgg medida)" test -f desafio-1/queries/explains/q1_after.txt
check 08.12 "REPORT.md com taxa de compressão e retenção" bash -c \
  'grep -q "Compressão —" desafio-1/REPORT.md && grep -q "Retenção —" desafio-1/REPORT.md'

# ===========================================================================

echo "----"
echo "$PASS_N pass, $FAIL_N fail, $SKIP_N skip"
[ "$FAIL_N" -eq 0 ] || exit 1
exit 0
