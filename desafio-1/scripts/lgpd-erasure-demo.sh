#!/usr/bin/env bash
# lgpd-erasure-demo.sh — prova o procedimento `anonimizar_conta` (S09) fim a
# fim: PII some da origem, histórico transacional permanece, auditoria fica
# registrada. Mesmo padrão do retention-demo.sh (etapa 08): dado sintético
# descartável, nunca uma conta real das 500k seedadas.
#
# Uso: ./desafio-1/scripts/lgpd-erasure-demo.sh
set -uo pipefail

PSQL="docker compose exec -T timescaledb psql -q -U trio -d trio_transactions"
PSQL_TA="docker compose exec -T timescaledb psql -qtA -U trio -d trio_transactions"

# CPF de teste reconhecido: 111.111.111-11 não passa em validação real de CPF
# (todos os dígitos iguais) — não colide com CPF de titular verdadeiro.
DEMO_CPF='11111111111'
DEMO_INST='DEMO-LGPD'

step() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

cleanup() {
  step "CLEANUP — removendo conta e transação sintéticas"
  $PSQL -c "DELETE FROM transactions WHERE source_institution='$DEMO_INST';" >/dev/null 2>&1
  $PSQL -c "DELETE FROM accounts WHERE institution_code='$DEMO_INST';" >/dev/null 2>&1
  local n
  n=$($PSQL_TA -c "SELECT count(*) FROM accounts WHERE institution_code='$DEMO_INST'")
  echo "  contas sintéticas restantes: $n (esperado: 0)"
}
trap cleanup EXIT

step "1. Criando conta sintética + 1 transação associada"
ACCOUNT_ID=$($PSQL_TA -c "
INSERT INTO accounts (account_number, institution_code, holder_document,
                       holder_doc_type, holder_name, account_type, status)
VALUES ('DEMO-0001', '$DEMO_INST', '$DEMO_CPF', 'cpf', 'Titular de Teste LGPD',
        'checking', 'active')
RETURNING id;")
echo "  account_id .............. $ACCOUNT_ID"

$PSQL -c "
INSERT INTO transactions
    (external_id, amount, currency, status, type,
     source_institution, destination_institution,
     source_account_id, created_at, updated_at)
VALUES (gen_random_uuid(), 250.00, 'BRL', 'settled', 'pix',
        '$DEMO_INST', '$DEMO_INST', $ACCOUNT_ID, now(), now());" >/dev/null

TX_BEFORE=$($PSQL_TA -c "SELECT count(*) FROM transactions WHERE source_account_id=$ACCOUNT_ID")
echo "  transações associadas ... $TX_BEFORE"

step "2. Estado ANTES da anonimização"
$PSQL -c "SELECT id, holder_name, holder_document, status FROM accounts WHERE id=$ACCOUNT_ID;"

step "3. Executando anonimizar_conta($ACCOUNT_ID, ...)"
$PSQL -c "CALL anonimizar_conta($ACCOUNT_ID, 'demo-script');"

step "4. Checklist de verificação (S09 § Checklist)"

# 1. A PII sumiu da origem?
HOLDER=$($PSQL_TA -c "SELECT holder_name FROM accounts WHERE id=$ACCOUNT_ID")
DOC=$($PSQL_TA -c "SELECT holder_document FROM accounts WHERE id=$ACCOUNT_ID")
echo "  1. holder_name .......... $HOLDER (esperado: ANONIMIZADO)"
echo "     holder_document ...... $DOC (esperado: prefixo ANON-)"

# 2. O histórico transacional permaneceu?
TX_AFTER=$($PSQL_TA -c "SELECT count(*) FROM transactions WHERE source_account_id=$ACCOUNT_ID")
echo "  2. transações permanecem  $TX_AFTER (esperado: $TX_BEFORE, inalterado)"

# 3/4. ClickHouse e CAggs não se aplicam neste ambiente (CH é etapa 11; CAggs
# já são livres de PII por design — nunca agregam por conta). Documentado,
# não testável antes da 11.

# 5. A auditoria registrou?
LOG_ROW=$($PSQL_TA -c "SELECT document_hash || ' | affected_rows=' || affected_rows
                       FROM lgpd_erasure_log WHERE requester='demo-script'
                       ORDER BY executed_at DESC LIMIT 1")
echo "  5. lgpd_erasure_log ..... $LOG_ROW"

step "5. Resultado"
OK=1
[ "$HOLDER" = "ANONIMIZADO" ] || OK=0
[[ "$DOC" == ANON-* ]] || OK=0
[ "$TX_AFTER" = "$TX_BEFORE" ] || OK=0
[ -n "$LOG_ROW" ] || OK=0

if [ "$OK" = "1" ]; then
  echo "  OK: PII removida, histórico preservado, auditoria registrada."
else
  echo "  FALHA: procedimento não se comportou como esperado."
  exit 1
fi
