#!/usr/bin/env bash
# wait-healthy.sh — espera os serviços do compose ficarem `healthy`, com timeout.
# Chamado por `make up`/`make up-core` logo após o `up -d`.
set -uo pipefail

TIMEOUT_S="${WAIT_HEALTHY_TIMEOUT:-180}"
INTERVAL_S=3
ELAPSED=0

echo "Aguardando healthchecks (timeout ${TIMEOUT_S}s)..."

while true; do
  STATUSES="$(docker compose ps --format '{{.Service}}: {{.Health}}' 2>/dev/null | grep -v ': $')"
  if [ -z "$STATUSES" ]; then
    echo "Nenhum container de pé — rode 'make up' ou 'make up-core' primeiro."
    exit 1
  fi

  UNHEALTHY="$(echo "$STATUSES" | grep -v 'healthy$' || true)"
  if [ -z "$UNHEALTHY" ]; then
    echo "Todos os serviços com healthcheck estão healthy."
    echo "$STATUSES"
    exit 0
  fi

  if [ "$ELAPSED" -ge "$TIMEOUT_S" ]; then
    echo "TIMEOUT após ${TIMEOUT_S}s. Serviços não healthy:"
    echo "$UNHEALTHY"
    echo "Diagnóstico: docker compose logs <serviço>"
    exit 1
  fi

  sleep "$INTERVAL_S"
  ELAPSED=$((ELAPSED + INTERVAL_S))
done
