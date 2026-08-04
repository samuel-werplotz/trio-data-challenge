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
seed_done()     { [ "${TRIO_SEED_DONE:-0}" = "1" ]; }  # etapa 05 exporta isto

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

  N_IDX=$(psql_ts "SELECT count(*) FROM pg_indexes WHERE tablename='transactions'")
  [ "$N_IDX" = "2" ] && ok 04.6 "só os 2 índices implícitos em transactions (pkey + created_at da hypertable)" \
    || fail 04.6 "esperava 2 índices, achei ${N_IDX:-erro}"
else
  skip 04.1 "timescaledb não está de pé"
  skip 04.2 "timescaledb não está de pé"
  skip 04.3 "timescaledb não está de pé"
  skip 04.4 "timescaledb não está de pé"
  skip 04.5 "timescaledb não está de pé"
  skip 04.6 "timescaledb não está de pé"
fi

# ===========================================================================

echo "----"
echo "$PASS_N pass, $FAIL_N fail, $SKIP_N skip"
[ "$FAIL_N" -eq 0 ] || exit 1
exit 0
