#!/usr/bin/env bash
# induzir-bloat-legado.sh — cria bloat real em legacy_accounts.
#
# Por que existe: a análise de migração para Aurora usa o bloat do legado como
# evidência (83,3% de linhas mortas, 70 MB para 80.000 linhas úteis). O bloat é
# INDUZIDO de propósito e declarado como tal em desafio-1/migration-analysis.md
# — um banco impecável ao lado tornaria a recomendação opinião, não argumento.
#
# O passo era manual e não estava em lugar nenhum: num ambiente do zero,
# `n_dead_tup` ficava em 0 e o teste 10.3 reprovava sem que houvesse como
# reproduzir o estado. Achado na etapa 99.
#
# Mecanismo: N rodadas de UPDATE que tocam TODA a tabela, sem VACUUM entre
# elas. No MVCC do PostgreSQL cada UPDATE escreve uma versão nova e deixa a
# anterior morta — é assim que bloat nasce em produção, quando o autovacuum
# não acompanha a taxa de escrita.
#
# Uso:  bash desafio-1/scripts/induzir-bloat-legado.sh [rodadas]
set -uo pipefail

RODADAS="${1:-5}"
PG="docker exec -i trio-postgres-legado psql -qtA -U trio -d trio_legado"

echo "== antes =="
$PG -c "SELECT 'linhas vivas: ' || n_live_tup || ' · mortas: ' || n_dead_tup ||
        ' · tamanho: ' || pg_size_pretty(pg_total_relation_size('legacy_accounts'))
        FROM pg_stat_user_tables WHERE relname='legacy_accounts'"

# `autovacuum = off` só nesta tabela: sem isso o autovacuum limpa as versões
# mortas no meio do processo e o bloat nunca se acumula. É a mesma condição de
# uma tabela quente em produção cujo autovacuum está mal dimensionado.
$PG -c "ALTER TABLE legacy_accounts SET (autovacuum_enabled = false)" >/dev/null

for i in $(seq 1 "$RODADAS"); do
  # Toca todas as linhas sem mudar o significado do dado: soma e subtrai o
  # mesmo valor. O saldo final é idêntico, mas cada linha ganha uma versão.
  $PG -c "UPDATE legacy_accounts SET balance = balance + 0.01" >/dev/null
  $PG -c "UPDATE legacy_accounts SET balance = balance - 0.01" >/dev/null
  echo "  rodada $i/$RODADAS"
done

# Estatística de bloat só aparece depois de ANALYZE — sem ele, pg_stat_user_tables
# reporta o estado anterior e parece que nada aconteceu.
$PG -c "ANALYZE legacy_accounts" >/dev/null

echo "== depois =="
$PG -c "SELECT 'linhas vivas: ' || n_live_tup || ' · mortas: ' || n_dead_tup ||
        ' (' || round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) || '%)' ||
        ' · tamanho: ' || pg_size_pretty(pg_total_relation_size('legacy_accounts'))
        FROM pg_stat_user_tables WHERE relname='legacy_accounts'"

echo
echo "O autovacuum segue DESLIGADO nesta tabela — é o que mantém o bloat para a"
echo "análise. Para devolver ao normal:"
echo "  ALTER TABLE legacy_accounts SET (autovacuum_enabled = true); VACUUM FULL legacy_accounts;"
