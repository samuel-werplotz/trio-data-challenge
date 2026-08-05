#!/usr/bin/env bash
# saturacao-pipeline.sh — teste de carga em patamares do pipeline
# TimescaleDB -> ClickHouse.
#
# Por que existe: a freshness de ~10s do ADR foi medida em regime OCIOSO, e o
# ADR projeta 10x no papel. A pergunta "e a 5.800 escritas/s?" nao tinha
# numero. Este script gera escrita crescente na origem e mede, em cada
# patamar, o que o pipeline devolve — lag, freshness, taxa de erro e onde
# satura.
#
# Encaixe no fluxo: roda contra o ambiente de pe, escreve em `transactions`
# com uma faixa de external_id identificavel e REMOVE tudo ao final (nas 3
# pontas: raw, e as 2 MVs agregadas, que nao recalculam sozinhas — ver
# desvios das etapas 12 e 16).
#
# Uso:  bash scripts/saturacao-pipeline.sh [--cleanup]
set -uo pipefail

PGC="docker exec -i trio-timescaledb psql -qtA -U trio -d trio_transactions"
CHC="docker exec -i trio-clickhouse clickhouse-client -u trio --password ${CLICKHOUSE_PASSWORD:-trio2024}"

# Marca das linhas sinteticas. A instituicao '999' nao existe no seed (que usa
# codigos reais de bancos) nem no Dictionary: isso torna a limpeza exata e
# evita contaminar qualquer agregado por instituicao real.
MARCA_INST="999"
SAIDA="desafio-2/saturacao-resultado.md"

limpar() {
  echo "== limpeza =="
  local n_pg n_ch
  $PGC -c "DELETE FROM transactions WHERE source_institution = '$MARCA_INST'" >/dev/null 2>&1
  n_pg=$($PGC -c "SELECT count(*) FROM transactions WHERE source_institution='$MARCA_INST'" 2>/dev/null | tr -d '\r ')
  # A raw e as 2 MVs precisam ser limpas SEPARADAMENTE: MV no ClickHouse e
  # gatilho de insercao, nao view que recalcula quando a origem muda.
  $CHC -q "ALTER TABLE trio_analytics.transactions_raw DELETE WHERE source_institution='$MARCA_INST' SETTINGS mutations_sync=2" >/dev/null 2>&1
  $CHC -q "ALTER TABLE trio_analytics.daily_by_institution DELETE WHERE source_institution='$MARCA_INST' SETTINGS mutations_sync=2" >/dev/null 2>&1
  $CHC -q "ALTER TABLE trio_analytics.status_funnel DELETE WHERE source_institution='$MARCA_INST' SETTINGS mutations_sync=2" >/dev/null 2>&1
  n_ch=$($CHC -q "SELECT count() FROM trio_analytics.transactions_raw WHERE source_institution='$MARCA_INST'" 2>/dev/null | tr -d '\r ')
  echo "  origem: ${n_pg:-?} linhas sinteticas restantes · destino: ${n_ch:-?}"
  echo "  totais: PG=$($PGC -c 'SELECT count(*) FROM transactions' | tr -d '\r ') CH=$($CHC -q 'SELECT count() FROM trio_analytics.transactions_raw' | tr -d '\r ')"
}

[ "${1:-}" = "--cleanup" ] && { limpar; exit 0; }

# Le uma metrica escalar do endpoint Prometheus do worker.
metrica() { curl -s localhost:8001/metrics | awk -v k="$1" '$1==k {print $2; exit}'; }

ACUM=0   # linhas sinteticas acumuladas, para conferir a entrega patamar a patamar

echo "== baseline =="
PG0=$($PGC -c "SELECT count(*) FROM transactions" | tr -d '\r ')
CH0=$($CHC -q "SELECT count() FROM trio_analytics.transactions_raw" | tr -d '\r ')
ERR0=$(curl -s localhost:8001/metrics | awk '/^sync_errors_total/ {s+=$2} END {print s+0}')
echo "  origem=$PG0 destino=$CH0 erros=$ERR0"

mkdir -p "$(dirname "$SAIDA")"
{
  echo "# Teste de saturacao do pipeline — resultado"
  echo
  echo "Gerado por \`scripts/saturacao-pipeline.sh\` em $(date -u '+%Y-%m-%d %H:%M UTC')."
  echo "Ambiente: Docker local (ver \`scripts/ambiente/DOCKER-LOCAL.md\`), nao AWS."
  echo
  echo "| Patamar alvo | Linhas | Tempo de escrita | Taxa real (linhas/s) | Lag apos (s) | Freshness (s) | Entregues | Erros |"
  echo "|---|---|---|---|---|---|---|---|"
} > "$SAIDA"

# Patamares: 500 -> 1000 -> 3000 -> 5800 -> 60000.
#
# 5800/s e o pico projetado do cenario 10x no ADR. O patamar de 60.000 nao e
# "10x o pico": e o unico que ULTRAPASSA BATCH_MAX_ROWS (50.000) num unico
# statement, e por isso o unico que exercita a retomada dentro de um mesmo
# updated_at. Foi ele que revelou o deadlock de watermark corrigido na 20.5 —
# os 4 primeiros passavam com folga e nao provavam nada sobre o limite.
for ALVO in 500 1000 3000 5800 60000; do
  echo "== patamar ${ALVO}/s =="
  # Gera ALVO linhas o mais rapido possivel: generate_series num unico INSERT
  # e o caminho mais proximo de uma rajada real na origem.
  T_INI=$(date +%s.%N)
  $PGC -c "
    INSERT INTO transactions (
      external_id, created_at, updated_at, type, status, amount, currency,
      source_institution, destination_institution,
      source_account_id, destination_account_id, metadata
    )
    SELECT
      gen_random_uuid(), now(), now(),
      'pix', 'pending', (random()*1000)::numeric(18,2), 'BRL',
      '$MARCA_INST', '$MARCA_INST',
      1, 2, '{\"saturacao\":true}'::jsonb
    FROM generate_series(1, $ALVO);" >/dev/null 2>&1
  T_FIM=$(date +%s.%N)

  DUR=$(awk -v a="$T_INI" -v b="$T_FIM" 'BEGIN{printf "%.2f", b-a}')
  TAXA=$(awk -v n="$ALVO" -v d="$DUR" 'BEGIN{printf "%.0f", (d>0? n/d : 0)}')

  # Espera o pipeline drenar. Lote acima de BATCH_MAX_ROWS precisa de mais de
  # um ciclo, entao a espera acompanha o tamanho.
  if [ "$ALVO" -gt 50000 ]; then sleep 60; else sleep 35; fi

  LAG=$(metrica sync_lag_seconds)
  LAST=$(metrica sync_last_success_timestamp)
  AGORA=$(date +%s)
  FRESH=$(awk -v a="$AGORA" -v l="${LAST:-0}" 'BEGIN{printf "%.0f", a-l}')
  ERRN=$(curl -s localhost:8001/metrics | awk '/^sync_errors_total/ {s+=$2} END {print s+0}')
  ERRD=$((ERRN - ERR0))

  # Entrega por patamar, nao so no fim: e a coluna que denuncia o lote que
  # nao chegou. Sem ela, o total no fim mascara qual patamar perdeu linha.
  ENTREGUE=$($CHC -q "SELECT count() FROM trio_analytics.transactions_raw WHERE source_institution='$MARCA_INST'" | tr -d '\r ')
  ESPERADO=$((ACUM + ALVO)); ACUM=$ESPERADO
  if [ "$ENTREGUE" = "$ESPERADO" ]; then MARCA="$ENTREGUE/$ESPERADO ✅"; else MARCA="**$ENTREGUE/$ESPERADO**"; fi

  LAG_R=$(awk -v v="${LAG:-0}" 'BEGIN{printf "%.1f", v}')
  printf "| %s/s | %s | %ss | %s | %s | %s | %s | %s |\n" \
    "$ALVO" "$ALVO" "$DUR" "$TAXA" "$LAG_R" "$FRESH" "$MARCA" "$ERRD" >> "$SAIDA"
  echo "  escreveu $ALVO em ${DUR}s (${TAXA}/s) · lag=${LAG_R}s freshness=${FRESH}s entregues=$ENTREGUE/$ESPERADO erros=+${ERRD}"
done

# Confere que tudo que entrou na origem chegou ao destino.
PG_SINT=$($PGC -c "SELECT count(*) FROM transactions WHERE source_institution='$MARCA_INST'" | tr -d '\r ')
CH_SINT=$($CHC -q "SELECT count() FROM trio_analytics.transactions_raw WHERE source_institution='$MARCA_INST'" | tr -d '\r ')
{
  echo
  echo "## Integridade"
  echo
  echo "| | Linhas sinteticas |"
  echo "|---|---|"
  echo "| Origem (TimescaleDB) | $PG_SINT |"
  echo "| Destino (ClickHouse) | $CH_SINT |"
  echo
  if [ "$PG_SINT" = "$CH_SINT" ]; then
    echo "**Nenhuma perda**: o pipeline entregou 100% do que foi escrito."
  else
    echo "**Divergencia de $((PG_SINT - CH_SINT)) linhas** — investigar antes de concluir."
  fi
} >> "$SAIDA"

echo "== resultado em $SAIDA =="
cat "$SAIDA"
limpar
