#!/usr/bin/env bash
# backup-all.sh — executa o backup dos TRÊS bancos (PDF § 5.2 A.1).
#
#   TimescaleDB      pgBackRest -> MinIO (S3)   físico, full/incr, com WAL (PITR)
#   PostgreSQL legado pgBackRest -> MinIO (S3)  físico, full/incr, com WAL (PITR)
#   ClickHouse       BACKUP nativo -> disco     físico, full
#
# Uso:  bash desafio-3/backup/backup-all.sh [full|incr]
#       CH_BACKUP=0 bash ... (pula o ClickHouse, para agenda separada)
#
# Em produção este script é o alvo do cron/EventBridge. A agenda e a retenção
# de cada banco estão documentadas em desafio-3/backup/README.md.
set -uo pipefail

TIPO="${1:-full}"
[ "$TIPO" = "full" ] || [ "$TIPO" = "incr" ] || { echo "uso: $0 [full|incr]"; exit 2; }

FALHAS=0
titulo() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
erro()   { printf '\033[31mFALHOU: %s\033[0m\n' "$1"; FALHAS=$((FALHAS+1)); }

# pgBackRest roda como postgres DENTRO do container do banco: ele lê o PGDATA
# direto e é o mesmo binário que o archive_command chama a cada segmento de WAL.
pgbr() {
  local container="$1" stanza="$2"; shift 2
  docker exec -u postgres "$container" pgbackrest --stanza="$stanza" "$@"
}

titulo "1/3 · TimescaleDB (stanza timescale) — $TIPO"
T0=$(date +%s)
if pgbr trio-timescaledb timescale --type="$TIPO" backup 2>&1 | grep -E "backup size|ERROR"; then
  echo "duração: $(( $(date +%s) - T0 ))s"
else
  erro "backup do TimescaleDB"
fi

titulo "2/3 · PostgreSQL legado (stanza legado) — $TIPO"
T0=$(date +%s)
if pgbr trio-postgres-legado legado --type="$TIPO" backup 2>&1 | grep -E "backup size|ERROR"; then
  echo "duração: $(( $(date +%s) - T0 ))s"
else
  erro "backup do PostgreSQL legado"
fi

titulo "3/3 · ClickHouse (BACKUP nativo)"
if [ "${CH_BACKUP:-1}" = "1" ]; then
  # Nome com timestamp: o ClickHouse recusa sobrescrever um backup existente,
  # então um nome fixo quebraria a partir da segunda execução.
  NOME="trio_analytics_$(date +%Y%m%dT%H%M%S).zip"
  T0=$(date +%s)
  if docker exec trio-clickhouse clickhouse-client -u trio --password trio2024 \
       -q "BACKUP DATABASE trio_analytics TO Disk('backups','$NOME')" 2>&1 | grep -q BACKUP_CREATED; then
    echo "$NOME criado — duração: $(( $(date +%s) - T0 ))s"
    # Retenção: mantém os 3 mais recentes. O ClickHouse não expira sozinho,
    # ao contrário do pgBackRest (repo1-retention-full).
    docker exec trio-clickhouse sh -c \
      'cd /var/lib/clickhouse/backups 2>/dev/null && ls -1t *.zip 2>/dev/null | tail -n +4 | xargs -r rm -f' 2>/dev/null
  else
    erro "backup do ClickHouse"
  fi
else
  echo "pulado (CH_BACKUP=0)"
fi

titulo "Inventário"
echo "--- TimescaleDB ---"
pgbr trio-timescaledb timescale info 2>/dev/null | grep -E "status|full backup|incr backup|wal archive" | head -8
echo "--- Legado ---"
pgbr trio-postgres-legado legado info 2>/dev/null | grep -E "status|full backup|incr backup" | head -6
echo "--- ClickHouse ---"
docker exec trio-clickhouse sh -c 'ls -lh /var/lib/clickhouse/backups/*.zip 2>/dev/null | awk "{print \$9, \$5}"' 2>/dev/null \
  || echo "(nenhum)"

if [ "$FALHAS" -eq 0 ]; then
  printf '\n\033[32mOK — os 3 bancos com backup concluído\033[0m\n'
  exit 0
fi
printf '\n\033[31m%d falha(s)\033[0m\n' "$FALHAS"
exit 1
