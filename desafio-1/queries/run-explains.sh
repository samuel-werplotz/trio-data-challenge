#!/usr/bin/env bash
# run-explains.sh — ritual de medição: 4 execuções, 1ª descartada, mediana das 3.
# Para cada query: roda 4x, descarta a 1ª (aquece o cache), guarda a mediana
# das 3 restantes, salva o EXPLAIN da última execução (mesmo plano, já quente)
# em qN_<suffix>.txt com Buffers: shared hit vs read visível.
#
# Uso: ./run-explains.sh before   (Q1-Q4 ingênuas, etapa 06 — já rodado, não repetir)
#      ./run-explains.sh after    (versões otimizadas, etapa 07)
SUFFIX="${1:?uso: run-explains.sh before|after}"
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
OUT_DIR="explains"
mkdir -p "$OUT_DIR"

PSQL="docker compose exec -T timescaledb psql -q -U trio -d trio_transactions"

# extrai "Execution Time: N ms" da saída do EXPLAIN ANALYZE
exec_time_ms() {
  grep -oE 'Execution Time: [0-9.]+ ms' | grep -oE '[0-9.]+'
}

median3() {
  # mediana de exatamente 3 números, um por linha, via stdin
  sort -n | awk 'NR==2'
}

run_query() {
  local id="$1" file="$2"
  echo "=== $id ($file) ==="
  local times=()
  for i in 1 2 3 4; do
    out=$($PSQL -c "EXPLAIN (ANALYZE, BUFFERS, VERBOSE) $(cat "$file")" 2>&1)
    t=$(echo "$out" | exec_time_ms)
    if [ "$i" -eq 1 ]; then
      echo "  execução 1 (descartada, aquece cache): ${t}ms"
    else
      echo "  execução $i: ${t}ms"
      times+=("$t")
      last_out="$out"
    fi
  done
  local med
  med=$(printf '%s\n' "${times[@]}" | median3)
  {
    echo "-- Query: $id"
    echo "-- Arquivo fonte: $file"
    echo "-- Protocolo: 4 execuções, 1ª descartada (aquece cache), mediana das 3 seguintes = ${med}ms"
    echo "-- Tempos das 3 execuções medidas (ms): ${times[*]}"
    echo "-- EXPLAIN abaixo é da última execução (cache já quente, mesmo plano)"
    echo "--"
    echo "$last_out"
  } > "$OUT_DIR/${id}_${SUFFIX}.txt"
  echo "  mediana: ${med}ms -> $OUT_DIR/${id}_${SUFFIX}.txt"
  echo
}

if [ "$SUFFIX" = "before" ]; then
  run_query q1 q1_volume_por_tipo_status.sql
  run_query q2 q2_divergencias_reconciliacao.sql
  run_query q3 q3_top_instituicoes.sql
  run_query q4 q4_deteccao_duplicatas.sql
else
  # Q1 otimizada lê de cagg_volume_hourly (etapa 08); Q2/Q3/Q4 vêm da etapa 07.
  run_query q1 q1_volume_por_tipo_status_optimized.sql
  run_query q2 q2_divergencias_reconciliacao_optimized.sql
  run_query q3 q3_top_instituicoes_optimized.sql
  run_query q4 q4_optimized.sql
  # 3ª versão da Q3, lendo do CAgg de latência em vez do índice covering.
  # Arquivo separado (q3_cagg_after.txt) para não sobrescrever a medição da 07.
  run_query q3_cagg q3_top_instituicoes_cagg.sql
fi

echo "Concluído. Ver $OUT_DIR/qN_${SUFFIX}.txt"
