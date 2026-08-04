#!/usr/bin/env bash
# restore-drill.sh — exercício de recuperação exigido pelo PDF § 5.2 A.2:
# "simule a perda de dados (DELETE de transações em um período) e restaure a
#  partir do backup. Documente o passo a passo com timestamps e validações
#  (contagem antes, depois da perda, e após recovery)."
#
# Estratégia: PITR (Point-In-Time Recovery) para uma instância PARALELA, nunca
# sobre o banco principal. Restaurar por cima do dataset de produção para provar
# que o backup funciona é o tipo de teste que vira o próprio incidente.
#
# O que ele exercita de verdade: o WAL arquivado. Um backup full sozinho só
# recupera até o instante em que foi tirado; a perda simulada aqui acontece
# DEPOIS do último full, então só o replay do WAL até um instante escolhido
# recupera as linhas. É a diferença entre ter backup e ter RPO.
set -uo pipefail

# Git Bash (MSYS) reescreve argumentos que parecem caminho POSIX para caminho
# Windows: '/var/lib/postgresql/drill' viraria 'C:/Program Files/Git/var/...' e
# o pgBackRest recusa com "must begin with / for 'pg1-path'". Os caminhos aqui
# são do container, não do host — a conversão precisa ficar desligada.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

STANZA=timescale
CONTAINER=trio-timescaledb
DRILL_DIR=/var/lib/postgresql/drill        # PGDATA da instância restaurada
DRILL_PORT=5499
INST="DRILL-$(date +%H%M%S)"               # marca as linhas deste exercício
PSQL="docker exec $CONTAINER psql -U trio -d trio_transactions -tAc"

ts()     { date -u +%Y-%m-%dT%H:%M:%SZ; }
titulo() { printf '\n\033[1m== %s  [%s] ==\033[0m\n' "$1" "$(ts)"; }
limpar() {
  docker exec -u postgres "$CONTAINER" bash -c "
    pg_ctl -D $DRILL_DIR -m immediate stop >/dev/null 2>&1; rm -rf $DRILL_DIR" 2>/dev/null
  $PSQL "DELETE FROM transactions WHERE source_institution='$INST'" >/dev/null 2>&1
  # O sync-worker pode ter propagado as linhas do drill ao ClickHouse antes do
  # DELETE. Limpa raw + as 2 MVs: elas são incrementais e contam inserções, então
  # apagar da raw não desfaz o agregado. Sem isto, cada execução do drill deixa
  # resíduo e o teste 12.6 (MV bate com a raw) passa a falhar.
  for t in transactions_raw daily_by_institution status_funnel; do
    docker exec trio-clickhouse clickhouse-client -u trio --password trio2024 -q \
      "ALTER TABLE trio_analytics.$t DELETE WHERE source_institution='$INST' SETTINGS mutations_sync=2" >/dev/null 2>&1
  done
}
trap limpar EXIT

titulo "0 · Pré-requisitos"
docker exec -u postgres "$CONTAINER" pgbackrest --stanza=$STANZA check >/dev/null 2>&1 \
  || { echo "pgbackrest check falhou — rode backup-all.sh antes"; exit 1; }
echo "stanza '$STANZA' íntegra, WAL sendo arquivado"
limpar   # resíduo de execução anterior interrompida

titulo "1 · Estado inicial"
# Backup incremental antes de começar. Sem ele, o `restore` parte do último full
# disponível — que pode ser de horas atrás e conter linhas de execuções
# anteriores deste mesmo drill, com outro sufixo em DRILL-*. O replay do WAL
# ainda chegaria ao alvo correto, mas a instância restaurada viria com esse
# resíduo e a validação compararia coisas diferentes.
# Custo real: 1s (o incremental sobre 3,1 GB deu 424 KB).
echo "backup incremental antes do exercício..."
docker exec -u postgres "$CONTAINER" pgbackrest --stanza=$STANZA --type=incr backup 2>&1 \
  | grep -E "backup size|ERROR" | tail -1

# As linhas do drill são sintéticas e marcadas: o dataset de 10M nunca é tocado.
for i in 1 2 3 4 5; do
  $PSQL "INSERT INTO transactions (external_id, amount, currency, status, type,
         source_institution, destination_institution, created_at)
         VALUES (gen_random_uuid(), 100.0$i,'BRL','settled','pix','$INST','002', now())" >/dev/null
done
ANTES=$($PSQL "SELECT count(*) FROM transactions WHERE source_institution='$INST'" | tr -d '\r ')
SOMA_ANTES=$($PSQL "SELECT coalesce(sum(amount),0) FROM transactions WHERE source_institution='$INST'" | tr -d '\r ')
echo "CONTAGEM ANTES DA PERDA:  $ANTES linhas | soma R\$ $SOMA_ANTES"

# Força um switch de WAL: o segmento com os INSERTs precisa estar ARQUIVADO no
# repositório, senão o replay não tem como reconstruí-los.
$PSQL "SELECT pg_switch_wal()" >/dev/null
sleep 3

# Marca temporal do recovery. O PITR vai parar exatamente aqui: depois dos
# INSERTs, antes do DELETE.
ALVO=$($PSQL "SELECT now()" | tr -d '\r' | sed 's/ *$//')
echo "ALVO DO PITR:            $ALVO"
sleep 2

titulo "2 · Simulando a perda (DELETE)"
$PSQL "DELETE FROM transactions WHERE source_institution='$INST'" >/dev/null
DEPOIS=$($PSQL "SELECT count(*) FROM transactions WHERE source_institution='$INST'" | tr -d '\r ')
echo "CONTAGEM DEPOIS DA PERDA: $DEPOIS linhas  (esperado 0)"
$PSQL "SELECT pg_switch_wal()" >/dev/null
sleep 3

titulo "3 · Restaurando para instância paralela (PITR)"
T_INICIO=$(date +%s)
docker exec -u postgres "$CONTAINER" bash -c "rm -rf $DRILL_DIR && mkdir -p $DRILL_DIR && chmod 700 $DRILL_DIR"
# --type=time + --target: replay do WAL até o instante escolhido e para.
# --delta reaproveita o que já existe; aqui o diretório está vazio, então é full.
docker exec -u postgres "$CONTAINER" pgbackrest --stanza=$STANZA \
  --pg1-path=$DRILL_DIR --type=time --target="$ALVO" --target-action=promote \
  restore 2>&1 | grep -E "ERROR|restore command end" | tail -2

titulo "4 · Subindo a instância restaurada na porta $DRILL_PORT"
docker exec -u postgres "$CONTAINER" bash -c "
  # A instância restaurada não deve arquivar WAL: ela é efêmera e escreveria
  # lixo no repositório real, corrompendo o histórico do banco de produção.
  echo \"archive_mode = off\"            >> $DRILL_DIR/postgresql.auto.conf
  echo \"port = $DRILL_PORT\"            >> $DRILL_DIR/postgresql.auto.conf
  # O Postgres recusa concluir o recovery se estes parâmetros forem MENORES que
  # os do primário quando o backup foi tirado — 'recovery aborted because of
  # insufficient parameter settings'. Eles dimensionam estruturas de memória
  # compartilhada que o replay do WAL precisa reconstruir, então a réplica não
  # pode ser menor que a origem. Espelham o que está no docker-compose.
  echo \"max_connections = 200\"         >> $DRILL_DIR/postgresql.auto.conf
  echo \"max_wal_senders = 10\"          >> $DRILL_DIR/postgresql.auto.conf
  echo \"max_replication_slots = 10\"    >> $DRILL_DIR/postgresql.auto.conf
  # A instância paralela divide a RAM com a principal: shared_buffers menor
  # evita competir por memória com o banco que está em uso.
  echo \"shared_buffers = 256MB\"        >> $DRILL_DIR/postgresql.auto.conf
  pg_ctl -D $DRILL_DIR -o '-p $DRILL_PORT' -w -t 120 -l $DRILL_DIR/drill.log start" 2>&1 | tail -2

for i in $(seq 1 40); do
  docker exec "$CONTAINER" pg_isready -p $DRILL_PORT -U trio >/dev/null 2>&1 && break
  sleep 2
done
T_FIM=$(date +%s)
RTO=$(( T_FIM - T_INICIO ))

titulo "5 · Validação"
DRILL_PSQL="docker exec $CONTAINER psql -U trio -p $DRILL_PORT -d trio_transactions -tAc"
RECUP=$($DRILL_PSQL "SELECT count(*) FROM transactions WHERE source_institution='$INST'" | tr -d '\r ')
SOMA_RECUP=$($DRILL_PSQL "SELECT coalesce(sum(amount),0) FROM transactions WHERE source_institution='$INST'" | tr -d '\r ')
TOTAL_RECUP=$($DRILL_PSQL "SELECT count(*) FROM transactions" | tr -d '\r ')
# Resíduo de execuções anteriores na instância restaurada indicaria que o
# `restore` partiu de um backup base velho — o cenário que o incremental do
# passo 1 evita. Se aparecer, a validação estaria comparando dado de outro drill.
RESIDUO=$($DRILL_PSQL "SELECT count(*) FROM transactions WHERE source_institution LIKE 'DRILL-%' AND source_institution <> '$INST'" | tr -d '\r ')

printf '\n  %-34s %s\n' "CONTAGEM ANTES DA PERDA:"   "$ANTES linhas | R\$ $SOMA_ANTES"
printf '  %-34s %s\n'   "CONTAGEM DEPOIS DA PERDA:"  "$DEPOIS linhas"
printf '  %-34s %s\n'   "CONTAGEM APÓS O RECOVERY:"  "$RECUP linhas | R\$ $SOMA_RECUP"
printf '  %-34s %s\n'   "TOTAL NA INSTÂNCIA RESTAURADA:" "$TOTAL_RECUP linhas"
printf '  %-34s %s\n'   "RESÍDUO DE OUTROS DRILLS:"      "${RESIDUO:-0} linhas (esperado 0)"
printf '\n  %-34s %ss\n' "RTO MEDIDO (restore + subir):" "$RTO"
# RPO: o quanto de dado se perderia numa falha real. Com archive_timeout=60, o
# pior caso é o último minuto de WAL ainda não arquivado.
printf '  %-34s %s\n'   "RPO (archive_timeout):"      "60s (pior caso)"

echo ""
if [ "$RECUP" = "$ANTES" ] && [ "$SOMA_RECUP" = "$SOMA_ANTES" ]; then
  printf '\033[32mOK — %s linhas recuperadas, soma idêntica (R$ %s). Perda revertida.\033[0m\n' "$RECUP" "$SOMA_RECUP"
  exit 0
fi
printf '\033[31mFALHOU — esperava %s linhas / R$ %s, obteve %s / R$ %s\033[0m\n' \
  "$ANTES" "$SOMA_ANTES" "$RECUP" "$SOMA_RECUP"
exit 1
