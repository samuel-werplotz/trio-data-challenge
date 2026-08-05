#!/usr/bin/env bash
# ha-smoke.sh — prova que o modo HA (docker-compose.ha.yml) replica de verdade.
#
# Não basta o cluster "subir": o que importa é o dado atravessar as réplicas, a
# leitura sobreviver à queda de um nó e o nó que volta se recuperar sozinho.
# Este script verifica os três.
#
# Pré-requisito:
#   docker compose -f docker-compose.yml -f docker-compose.ha.yml up -d
#
# Uso:
#   bash scripts/tests/ha-smoke.sh
set -uo pipefail

R1="${R1:-trio-clickhouse}"
R2="${R2:-trio-clickhouse-r2}"
CH_USER="${CLICKHOUSE_USER:-trio}"
CH_PASS="${CLICKHOUSE_PASSWORD:-trio2024}"
TBL="trio_analytics.ha_smoke"

PASS=0; FAIL=0

ok()   { printf '  \033[1;32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); }
info() { printf '\033[1;36m%s\033[0m\n' "$1"; }

q1() { docker exec "$R1" clickhouse-client -u "$CH_USER" --password "$CH_PASS" -q "$1" 2>/dev/null; }
q2() { docker exec "$R2" clickhouse-client -u "$CH_USER" --password "$CH_PASS" -q "$1" 2>/dev/null; }

limpar() { q1 "DROP TABLE IF EXISTS ${TBL} ON CLUSTER trio_cluster SYNC" >/dev/null 2>&1; }

for c in "$R1" "$R2"; do
  if ! docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
    echo "ERRO: ${c} não está de pé. Suba o modo HA antes:"
    echo "  docker compose -f docker-compose.yml -f docker-compose.ha.yml up -d"
    exit 1
  fi
done

trap limpar EXIT
limpar

echo
info "── 1 · topologia ──"

[ "$(q1 "SELECT count() FROM system.zookeeper WHERE path='/'")" -ge 1 ] \
  && ok "réplica 1 conectada ao Keeper" || bad "réplica 1 não fala com o Keeper"

[ "$(q2 "SELECT count() FROM system.zookeeper WHERE path='/'")" -ge 1 ] \
  && ok "réplica 2 conectada ao Keeper" || bad "réplica 2 não fala com o Keeper"

[ "$(q1 "SELECT count() FROM system.clusters WHERE cluster='trio_cluster'")" = "2" ] \
  && ok "cluster trio_cluster com 2 réplicas" || bad "cluster não tem 2 réplicas"

# Macros distintas: dois nós com o mesmo {replica} colidem no Keeper; com
# {shard} distinto viram shards separados e o dado se divide em vez de duplicar.
M1=$(q1 "SELECT substitution FROM system.macros WHERE macro='replica'")
M2=$(q2 "SELECT substitution FROM system.macros WHERE macro='replica'")
[ -n "$M1" ] && [ -n "$M2" ] && [ "$M1" != "$M2" ] \
  && ok "macros {replica} distintas ($M1 / $M2)" || bad "macros {replica} iguais ou vazias"

S1=$(q1 "SELECT substitution FROM system.macros WHERE macro='shard'")
S2=$(q2 "SELECT substitution FROM system.macros WHERE macro='shard'")
[ "$S1" = "$S2" ] && ok "macro {shard} igual nos dois ($S1) — replicam entre si" \
                  || bad "shards diferentes: viram shards separados, não réplicas"

info "── 2 · DDL ON CLUSTER ──"

q1 "CREATE TABLE IF NOT EXISTS ${TBL} ON CLUSTER trio_cluster
    ( id UInt64, v String, _version UInt64 )
    ENGINE = ReplicatedReplacingMergeTree('/clickhouse/tables/{shard}/ha_smoke','{replica}', _version)
    ORDER BY id" >/dev/null 2>&1

[ "$(q2 "EXISTS TABLE ${TBL}")" = "1" ] \
  && ok "DDL propagou para a réplica 2 sem ser executado nela" \
  || bad "tabela não existe na réplica 2"

info "── 3 · replicação de dados ──"

q1 "INSERT INTO ${TBL} VALUES (1,'via-r1',1),(2,'via-r1',1),(3,'via-r1',1)" >/dev/null 2>&1
sleep 5
[ "$(q2 "SELECT count() FROM ${TBL}")" = "3" ] \
  && ok "3 linhas escritas em r1 apareceram em r2" || bad "r2 não recebeu o dado de r1"

q2 "INSERT INTO ${TBL} VALUES (4,'via-r2',1)" >/dev/null 2>&1
sleep 5
[ "$(q1 "SELECT count() FROM ${TBL}")" = "4" ] \
  && ok "replicação é bidirecional (escrita em r2 chegou em r1)" || bad "r1 não recebeu o dado de r2"

info "── 4 · failover e recuperação ──"

docker stop "$R1" >/dev/null 2>&1
sleep 3

[ "$(q2 "SELECT count() FROM ${TBL}")" = "4" ] \
  && ok "leitura continua com a réplica 1 FORA" || bad "leitura falhou com r1 fora"

q2 "INSERT INTO ${TBL} VALUES (5,'r1-fora',1)" >/dev/null 2>&1
[ "$(q2 "SELECT count() FROM ${TBL}")" = "5" ] \
  && ok "escrita continua com a réplica 1 FORA (quórum de Keeper mantido)" \
  || bad "escrita falhou com r1 fora"

docker start "$R1" >/dev/null 2>&1
# Espera a réplica voltar e drenar a fila de replicação.
for _ in $(seq 1 30); do
  [ "$(q1 "SELECT count() FROM ${TBL}" 2>/dev/null)" = "5" ] && break
  sleep 2
done

[ "$(q1 "SELECT count() FROM ${TBL}")" = "5" ] \
  && ok "réplica 1 recuperou sozinha o que perdeu enquanto esteve fora" \
  || bad "réplica 1 não sincronizou após voltar"

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1;32m✓ %d verificações, 0 falhas — HA comprovado.\033[0m\n' "$PASS"
else
  printf '\033[1;31m✗ %d falha(s) em %d verificações.\033[0m\n' "$FAIL" "$((PASS+FAIL))"
fi
echo
[ "$FAIL" -eq 0 ]
