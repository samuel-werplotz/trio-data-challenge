#!/usr/bin/env bash
# init-stanzas.sh — cria as stanzas do pgBackRest nos 2 PostgreSQL.
#
# Encaixe no fluxo: roda UMA VEZ, depois de `up` e antes do primeiro
# `backup-all.sh`. A stanza é o "repositório lógico" de um banco no pgBackRest:
# sem ela, `archive-push` falha em silêncio a cada segmento de WAL e
# `backup-all.sh` não tem onde escrever.
#
# Por que este script existe: a criação das stanzas era um passo MANUAL, feito
# uma vez na etapa 13.5 e nunca escrito em lugar nenhum. Funcionava enquanto o
# volume sobrevivia; num ambiente do zero, 6 testes de backup reprovavam e não
# havia no repositório como reproduzir o setup. Achado na etapa 99, rodando a
# sequência completa pela primeira vez.
#
# Idempotente: `stanza-create` não reclama se a stanza já existe.
#
# Uso:  bash desafio-3/backup/init-stanzas.sh
set -uo pipefail

FALHAS=0
titulo() { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
erro()   { printf '\033[31mFALHOU: %s\033[0m\n' "$1"; FALHAS=$((FALHAS+1)); }

pgbr() {
  local container="$1" stanza="$2"; shift 2
  docker exec -u postgres "$container" pgbackrest --stanza="$stanza" "$@"
}

for PAR in "trio-timescaledb:timescale" "trio-postgres-legado:legado"; do
  CONTAINER="${PAR%%:*}"; STANZA="${PAR##*:}"
  titulo "$STANZA ($CONTAINER)"

  if pgbr "$CONTAINER" "$STANZA" stanza-create 2>&1 | tail -2; then
    echo "  stanza criada (ou já existia)"
  else
    erro "stanza-create falhou em $STANZA"; continue
  fi

  # `check` valida o caminho inteiro: conexão com o repositório S3, permissão
  # de escrita E o archive_command do próprio banco. É a diferença entre
  # "a stanza existe" e "o backup vai funcionar".
  # `check` valida o caminho inteiro numa tacada. Duas tentativas porque logo
  # após o seed o primeiro check pode pegar o archiver ainda drenando a fila de
  # WAL e abortar — na 2ª já passa.
  if pgbr "$CONTAINER" "$STANZA" check 2>&1 | tail -1; then
    echo "  check OK — repositório e archive_command funcionando"
  else
    sleep 5
    pgbr "$CONTAINER" "$STANZA" start >/dev/null 2>&1
    if pgbr "$CONTAINER" "$STANZA" check 2>&1 | tail -1; then
      echo "  check OK na 2ª tentativa (archiver estava drenando a fila)"
    else
      erro "check falhou em $STANZA"
    fi
  fi
done

# Força um switch de WAL: sem escrita nova, `archived_count` fica em 0 e o
# arquivamento parece quebrado quando na verdade nunca foi exercitado.
titulo "primeiro archive"
for C in trio-timescaledb trio-postgres-legado; do
  docker exec -u postgres "$C" psql -qtAc "SELECT pg_switch_wal()" >/dev/null 2>&1
done
sleep 5
for PAR in "trio-timescaledb:trio:trio_transactions" "trio-postgres-legado:trio:trio_legado"; do
  C="${PAR%%:*}"; REST="${PAR#*:}"; U="${REST%%:*}"; DB="${REST##*:}"
  # Usuário `trio`, não `postgres`: a imagem cria só o primeiro, e `psql -u
  # postgres` falha com "role does not exist" — o que devolvia string vazia e
  # parecia arquivamento quebrado.
  N=$(docker exec "$C" psql -qtA -U "$U" -d "$DB" \
      -c "SELECT archived_count FROM pg_stat_archiver" 2>/dev/null | tr -d '\r ')
  echo "  $C: archived_count=${N:-?}"
  [ -n "$N" ] && [ "$N" -gt 0 ] 2>/dev/null || erro "$C não arquivou nenhum WAL"
done

echo
if [ "$FALHAS" -eq 0 ]; then
  echo "Stanzas prontas. Próximo passo: bash desafio-3/backup/backup-all.sh full"
  exit 0
fi
echo "$FALHAS falha(s) — ver acima."
exit 1
