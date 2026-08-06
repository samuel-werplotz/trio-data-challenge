#!/usr/bin/env bash
# bootstrap.sh — leva o ambiente do zero ao estado completo, num comando.
#
# Por que este script existe: até a etapa 99, a sequência do zero tinha 4 passos
# que só existiam na cabeça de quem construiu o projeto — materialização dos
# CAggs, compressão inicial, criação das stanzas do pgBackRest e o RBAC do
# ClickHouse. Cada um foi executado UMA VEZ à mão e sobreviveu no volume; num
# ambiente novo, nada disso nascia, e a suíte reprovava 22 testes. Configuração
# que só existe no ambiente vivo é configuração que se perde.
#
# `docker compose up -d` sozinho já entrega o critério de aceite nº 1 do PDF
# (ambiente de pé + 10M carregados). Este script entrega o resto: agregados,
# compressão, backup e perfis de acesso.
#
# Idempotente: pode rodar de novo sem estragar nada.
#
# Uso:  bash scripts/bootstrap.sh
set -uo pipefail

PASSO=0
titulo() { PASSO=$((PASSO+1)); printf '\n\033[1m[%d/8] %s\033[0m\n' "$PASSO" "$1"; }
FALHAS=0
erro() { printf '\033[31m  FALHOU: %s\033[0m\n' "$1"; FALHAS=$((FALHAS+1)); }

PGTS="docker compose exec -T timescaledb psql -q -U trio -d trio_transactions"
CH="docker compose exec -T clickhouse clickhouse-client --user trio --password ${CLICKHOUSE_PASSWORD:-trio2024}"

titulo "Certificado do MinIO"
# A chave privada não é versionada (.gitignore), então num clone limpo ela não
# existe — e o MinIO monta essa pasta como /root/.minio/certs. Sem certificado
# ele não serve HTTPS, o healthcheck nunca fica verde, o minio-init não cria o
# bucket e o archive_command do WAL falha nos dois Postgres. Checar aqui troca
# esse encadeamento por uma linha de saída.
if [ -f desafio-3/backup/minio-certs/private.key ]; then
  echo "  já existe — pulado"
else
  echo "  ausente (clone limpo) — gerando"
  bash desafio-3/backup/gen-certs.sh 2>&1 | tail -2 || erro "gen-certs"
fi

titulo "Ambiente de pé e saudável"
docker compose up -d >/dev/null 2>&1
bash scripts/wait-healthy.sh 2>&1 | tail -1 || erro "healthcheck"

titulo "Seed (idempotente — pula se já carregado)"
until [ "$($PGTS -tAc "SELECT finished_at IS NOT NULL FROM seed_control" 2>/dev/null | tr -d '\r ')" = "t" ]; do
  echo "  carregando… $($PGTS -tAc 'SELECT count(*) FROM transactions' 2>/dev/null | tr -d '\r ') linhas"
  sleep 20
done
echo "  origem: $($PGTS -tAc 'SELECT count(*) FROM transactions' | tr -d '\r ') transações"

titulo "CAggs e compressão"
# `refresh_continuous_aggregate` NÃO roda dentro de bloco de transação, e o
# `docker-entrypoint-initdb.d` executa cada arquivo numa — por isso os CALLs de
# refresh do 04_caggs_policies.sql são pulados no init e precisam rodar aqui.
MSYS_NO_PATHCONV=1 $PGTS -f /docker-entrypoint-initdb.d/04_caggs_policies.sql >/dev/null 2>&1
N_CAGG=$($PGTS -tAc "SELECT count(*) FROM cagg_volume_hourly" | tr -d '\r ')
[ "${N_CAGG:-0}" -gt 0 ] 2>/dev/null && echo "  cagg_volume_hourly: $N_CAGG linhas" \
  || erro "CAgg vazio após o refresh"
# A política de compressão é agendada; forçar aqui evita esperar o job para o
# ambiente ficar representativo (a taxa de 5,0x do REPORT depende disso).
N_COMP=$($PGTS -tAc "SELECT count(*) FROM (SELECT compress_chunk(c, if_not_compressed => true) FROM show_chunks('transactions', older_than => INTERVAL '7 days') c) x" 2>/dev/null | tr -d '\r ')
echo "  chunks comprimidos: ${N_COMP:-0}"

titulo "Backfill do ClickHouse"
# A guarda compara com a ORIGEM, não com zero. O motivo é uma condição de
# corrida real, encontrada testando o caminho de um clone limpo: o sync-worker
# sobe junto no `up` e já ingere em tempo real enquanto o seed carrega. Quando o
# bootstrap chega aqui, o destino tem algumas milhares de linhas — nunca zero.
# Com a guarda antiga (`= 0`), o backfill era PULADO e o ambiente terminava com
# ~4 mil linhas no ClickHouse em vez de 10 milhões, sem nenhum erro na saída.
CH_N=$($CH -q 'SELECT count() FROM trio_analytics.transactions_raw' 2>/dev/null | tr -d '\r ')
TS_N=$($PGTS -tAc 'SELECT count(*) FROM transactions' 2>/dev/null | tr -d '\r ')
if [ "${CH_N:-0}" -lt "${TS_N:-1}" ] 2>/dev/null; then
  echo "  destino com ${CH_N:-0} de ${TS_N:-?} — rodando backfill"
  bash scripts/backfill-clickhouse.sh 2>&1 | tail -2
else
  echo "  destino já completo (${CH_N} linhas) — pulado"
fi
# O sync-worker ingere durante o seed, então o backfill relê algumas linhas que
# já entraram: `count()` fica acima de 10M com versões duplicadas pendentes de
# merge. Não é erro — é o ReplacingMergeTree funcionando — mas deixa o ambiente
# num estado que confunde qualquer conferência por contagem bruta.
$CH -q "OPTIMIZE TABLE trio_analytics.transactions_raw FINAL" >/dev/null 2>&1

# `OPTIMIZE` resolve a raw e NÃO resolve as MVs, e o motivo é o ponto: a MV
# disparou uma vez por versão inserida, então o agregado CONTOU a duplicata de
# forma permanente. AggregatingMergeTree não tem `_version` para colapsar — não
# há merge que desfaça. A única saída é reconstruir a partir da raw já
# deduplicada (`FINAL`). É a mesma armadilha das etapas 12 e 16 numa terceira
# forma: mexer na raw sem tratar a MV deixa as duas fora de sincronia.
if [ "$($CH -q 'SELECT count() FROM trio_analytics.transactions_raw' | tr -d '\r ')" \
     != "$($CH -q 'SELECT sum(n) FROM (SELECT countMerge(tx_count) AS n FROM trio_analytics.daily_by_institution GROUP BY day, source_institution, type)' | tr -d '\r ')" ]; then
  echo "  MVs divergentes da raw — reconstruindo a partir do dado deduplicado"
  $CH -q "TRUNCATE TABLE trio_analytics.daily_by_institution" >/dev/null 2>&1
  $CH -q "INSERT INTO trio_analytics.daily_by_institution
          SELECT toDate(created_at) AS day, source_institution, type,
                 countState(), sumState(amount), avgState(amount),
                 quantileState(0.95)(amount), quantileState(0.99)(amount),
                 countIfState(status='settled'), countIfState(status='failed'),
                 avgState(settlement_seconds)
            FROM trio_analytics.transactions_raw FINAL
           GROUP BY day, source_institution, type" >/dev/null 2>&1
  $CH -q "TRUNCATE TABLE trio_analytics.status_funnel" >/dev/null 2>&1
  $CH -q "INSERT INTO trio_analytics.status_funnel
          SELECT toStartOfHour(created_at) AS hour, type, source_institution, status,
                 countState(), avgState(settlement_seconds),
                 quantileState(0.5)(settlement_seconds),
                 quantileState(0.95)(settlement_seconds)
            FROM trio_analytics.transactions_raw FINAL
           GROUP BY hour, type, source_institution, status" >/dev/null 2>&1
fi
echo "  destino: $($CH -q 'SELECT count() FROM trio_analytics.transactions_raw' | tr -d '\r ') linhas"

titulo "RBAC do ClickHouse (perfil analytics_ro)"
# Versionado em init/clickhouse/02_rbac.sql, mas o init só roda em volume novo —
# aplicar aqui cobre também o ambiente que já existia.
docker cp init/clickhouse/02_rbac.sql trio-clickhouse:/tmp/02_rbac.sql >/dev/null 2>&1
MSYS_NO_PATHCONV=1 docker compose exec -T clickhouse clickhouse-client \
  --user trio --password "${CLICKHOUSE_PASSWORD:-trio2024}" --queries-file /tmp/02_rbac.sql >/dev/null 2>&1
$CH -q "SELECT name FROM system.users WHERE name='analytics_ro'" | grep -q analytics_ro \
  && echo "  analytics_ro criado" || erro "analytics_ro não foi criado"

titulo "Backup: stanzas do pgBackRest"
bash desafio-3/backup/init-stanzas.sh 2>&1 | tail -3 || erro "stanzas"
echo "  rode 'bash desafio-3/backup/backup-all.sh full' para o primeiro backup"

titulo "Bloat induzido no legado (evidência da análise Aurora)"
# O bloat é premissa declarada de migration-analysis.md: sem ele a recomendação
# vira opinião. Só induz se ainda não houver — o script é caro (10 UPDATEs
# sobre 80.000 linhas) e o efeito é cumulativo.
N_DEAD=$(docker compose exec -T postgres-legado psql -qtA -U trio -d trio_legado \
  -c "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='legacy_accounts'" 2>/dev/null | tr -d '\r ')
if [ "${N_DEAD:-0}" -gt 1000 ] 2>/dev/null; then
  echo "  bloat já presente ($N_DEAD linhas mortas) — pulado"
else
  bash desafio-1/scripts/induzir-bloat-legado.sh 2>&1 | tail -2
fi

echo
if [ "$FALHAS" -eq 0 ]; then
  echo "Ambiente completo. Valide com: bash scripts/health-check.sh"
  exit 0
fi
echo "$FALHAS falha(s) — ver acima."
exit 1
