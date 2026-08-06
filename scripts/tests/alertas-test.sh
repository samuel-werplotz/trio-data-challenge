#!/usr/bin/env bash
# alertas-test.sh — teste unitário das 6 regras de alerta do Prometheus.
#
# O que ele responde, e a suíte principal não respondia: as regras DISPARAM
# quando deveriam, e ficam quietas quando não deveriam. `run_all.sh` verifica
# que elas existem, carregam e estão saudáveis — três propriedades que o
# DicionarioDesatualizado cumpria enquanto media a série errada.
#
# Usa `promtool test rules`, que avalia as regras contra séries sintéticas com
# tempo SIMULADO. É o que torna viável testar um `for: 10m` em milissegundos, e
# o que permite exercitar cenários (worker morto, erro no pipeline) sem
# quebrar nada no ambiente de verdade.
#
# Uso:  bash scripts/tests/alertas-test.sh
set -uo pipefail

# No Git Bash (MSYS), um argumento que parece caminho absoluto Unix é reescrito
# para caminho Windows antes de chegar ao docker: /etc/prometheus/... virava
# C:/Program Files/Git/etc/prometheus/... e o promtool não achava o arquivo.
# O caminho aqui é DENTRO do container, então a conversão tem de ser desligada.
export MSYS_NO_PATHCONV=1

CONTAINER="${PROM_CONTAINER:-trio-prometheus}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "SKIP  container $CONTAINER fora do ar — suba com 'docker compose up -d'"
  exit 0
fi

echo "== teste unitário das regras de alerta =="

# O promtool resolve `rule_files` relativo ao diretório do arquivo de teste,
# então os dois precisam estar lado a lado — é o caso em /etc/prometheus.
if docker exec "$CONTAINER" promtool test rules /etc/prometheus/alert_tests.yml; then
  echo
  echo "OK — as 6 regras disparam e silenciam como especificado"
  exit 0
else
  echo
  echo "FALHOU — uma regra não se comporta como o teste espera."
  echo "  Isso é intencionalmente barulhento: alerta que não dispara é pior"
  echo "  que alerta ausente, porque cria confiança falsa."
  exit 1
fi
