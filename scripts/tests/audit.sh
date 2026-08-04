#!/usr/bin/env bash
# audit.sh — auditoria global do PLANO antes de começar a execução.
#
# Verifica se o orquestrador, a esteira de etapas e o vault estão íntegros e
# conformes ao PDF do desafio (fonte canônica). É a checagem de "posso começar?".
#
# NÃO confunda com run_all.sh:
#   run_all.sh  → testa o PRODUTO (containers, schema, dados). Cresce a cada etapa.
#   audit.sh    → testa o PLANO (arquivos de roadmap, regras, rastreio do PDF). Fixo.
#
# Roda em Bash (Git Bash no Windows), sem dependência de Docker ou de rede.
# Uso:
#   bash scripts/tests/audit.sh            # da raiz do repo
#   bash scripts/tests/audit.sh --verbose  # mostra também o que passou
#
# Estados: PASS / FAIL / WARN / SKIP
#   FAIL → impede o início. Exit 1.
#   WARN → revisar, mas não bloqueia (ex.: item que só existe após a etapa 01).
#   SKIP → pré-condição ausente (ex.: repo ainda não achatado).

set -uo pipefail

VERBOSE=0
[ "${1:-}" = "--verbose" ] && VERBOSE=1

PASS_N=0; FAIL_N=0; WARN_N=0; SKIP_N=0
FAILED_IDS=()

# ---------- localização ----------
# O script aceita ser chamado de qualquer lugar: sobe até achar CLAUDE.md.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT" || { echo "ERRO: não achei a raiz do repo"; exit 2; }

ROADMAP="scripts/roadmap"
VAULT="../vault-estudo"

# ---------- primitivas ----------
ok()   { PASS_N=$((PASS_N+1)); [ "$VERBOSE" = 1 ] && printf '  PASS  %-14s %s\n' "$1" "${2:-}"; return 0; }
bad()  { FAIL_N=$((FAIL_N+1)); FAILED_IDS+=("$1"); printf '  \033[31mFAIL\033[0m  %-14s %s\n' "$1" "${2:-}"; return 0; }
warn() { WARN_N=$((WARN_N+1)); printf '  \033[33mWARN\033[0m  %-14s %s\n' "$1" "${2:-}"; return 0; }
skip() { SKIP_N=$((SKIP_N+1)); printf '  SKIP  %-14s %s\n' "$1" "${2:-}"; return 0; }

# want <id> <descrição> <comando...> — PASS se o comando sai 0
want() { local id="$1" d="$2"; shift 2; if "$@" >/dev/null 2>&1; then ok "$id" "$d"; else bad "$id" "$d"; fi; }

# step_file <NN> — resolve o caminho de uma etapa do roadmap esteja ela ainda
# na raiz (aberta) ou em concluidas/ (fechada). Uso: grep_file A3.1 "$(step_file 06)" ...
step_file() {
  ls "$ROADMAP/$1"-*.md "$ROADMAP/concluidas/$1"-*.md 2>/dev/null | head -1
}

# grep_file <id> <arquivo> <regex> <descrição> — o arquivo precisa conter o padrão
grep_file() {
  local id="$1" f="$2" re="$3" d="$4"
  if [ ! -f "$f" ]; then bad "$id" "$d — arquivo ausente: $f"; return; fi
  if grep -qiE "$re" "$f"; then ok "$id" "$d"; else bad "$id" "$d — não achei /$re/ em $f"; fi
}

# grep_any <id> <descrição> <regex> <arquivos...> — o padrão precisa estar em ALGUM deles
grep_any() {
  local id="$1" d="$2" re="$3"; shift 3
  if grep -qriE "$re" "$@" 2>/dev/null; then ok "$id" "$d"; else bad "$id" "$d — não achei /$re/"; fi
}

sec() { printf '\n\033[1m%s\033[0m\n' "$1"; }

echo "════════════════════════════════════════════════════════════"
echo " AUDITORIA DO PLANO — Trio Data Challenge"
echo " raiz: $ROOT"
echo "════════════════════════════════════════════════════════════"

# ============================================================================
sec "1. Estrutura do orquestrador"
# ============================================================================
want A1.1 "CLAUDE.md existe na raiz"            test -f CLAUDE.md
want A1.2 "CLAUDE.md NÃO está dentro de scripts/" test ! -f scripts/CLAUDE.md
want A1.3 "roadmap/ existe"                      test -d "$ROADMAP"
want A1.4 "concluidas/ existe"                   test -d "$ROADMAP/concluidas"
want A1.5 "concluidas/.gitkeep existe"           test -f "$ROADMAP/concluidas/.gitkeep"
want A1.6 "LOG-EXECUCAO.md existe"               test -f "$ROADMAP/LOG-EXECUCAO.md"
want A1.7 "ficha de ambiente existe"             test -f scripts/ambiente/DOCKER-LOCAL.md
want A1.8 "run_all.sh existe"                    test -f scripts/tests/run_all.sh
want A1.9 "run_all.sh sai 0 (0 testes ainda)"    bash scripts/tests/run_all.sh

# CLAUDE.md precisa ser autossuficiente e enxuto
CM_LINES=$(wc -l < CLAUDE.md 2>/dev/null || echo 999)
if [ "$CM_LINES" -lt 110 ]; then ok A1.10 "CLAUDE.md com $CM_LINES linhas (meta <100)"
else bad A1.10 "CLAUDE.md inchado: $CM_LINES linhas"; fi
[ "$CM_LINES" -gt 100 ] && [ "$CM_LINES" -lt 110 ] && warn A1.10b "CLAUDE.md em $CM_LINES linhas, meta é <100"

# @import carrega no boot e anula a economia de contexto — só a MENÇÃO à regra é permitida
if grep -qE '^\s*@[A-Za-z./]' CLAUDE.md 2>/dev/null; then
  bad A1.11 "CLAUDE.md tem @import de verdade (proibido)"
else ok A1.11 "CLAUDE.md sem @import"; fi

# As 12 seções obrigatórias do orquestrador
for s in Operação "Escopo travado" "Arquitetura travada" "Regra de contexto" \
         "Política de impedimento" "Regra de comentário" "Regra de teste" "Regra de git" \
         "Checklist de fechamento" Esteira "Ficha de ambiente" "Estilo de resposta"; do
  grep_file "A1.s" CLAUDE.md "$s" "CLAUDE.md tem seção: $s"
done

# ============================================================================
sec "2. Esteira — 15 etapas + 99"
# ============================================================================
# Etapa fechada move de $ROADMAP para $ROADMAP/concluidas — procurar nos dois
# é o que faz esta seção continuar válida depois que a esteira anda.
# 18 = 15 originais + 99 + 13.5 (reconciliação) + 16 (lacunas do PDF).
# A esteira cresceu na reconciliação pós-auditoria; ver CLAUDE.md § 10.
N_STEPS=$(ls "$ROADMAP"/[0-9]*.md "$ROADMAP/concluidas"/[0-9]*.md 2>/dev/null | wc -l)
if [ "$N_STEPS" -eq 18 ]; then ok A2.1 "18 arquivos de etapa (15 + 99 + 13.5 + 16)"
else bad A2.1 "esperava 18 arquivos de etapa, achei $N_STEPS"; fi

for n in 01 02 03 04 05 06 07 08 09 10 11 12 13 13.5 14 15 16 99; do
  f=$(ls "$ROADMAP/$n"-*.md "$ROADMAP/concluidas/$n"-*.md 2>/dev/null | head -1)
  if [ -z "$f" ]; then bad "A2.$n" "etapa $n ausente"; continue; fi

  # As 10 seções do template fixo
  c=$(grep -cE '^## (ORIGEM|IMPEDITIVOS|ESTADO HERDADO|ESCOPO|PASSOS|CRITÉRIOS DE ACEITE|TESTES|ROLLBACK|STATUS|FECHAMENTO)$' "$f")
  [ "$c" -eq 10 ] || bad "A2.$n.tpl" "etapa $n: $c/10 seções do template"

  # ORIGEM nunca em branco — toda etapa nasce sabendo de onde vem
  o=$(awk '/^## ORIGEM/{getline; print; exit}' "$f")
  [ -n "$o" ] || bad "A2.$n.org" "etapa $n: ORIGEM vazia"

  # ESCOPO com as duas fronteiras
  grep -q '^Faz:' "$f"     || bad "A2.$n.faz" "etapa $n: falta 'Faz:'"
  grep -q '^Não faz:' "$f" || bad "A2.$n.nfz" "etapa $n: falta 'Não faz:'"

  # ROLLBACK com comando exato, não descrição em prosa
  grep -q '```' "$f" || bad "A2.$n.rbk" "etapa $n: ROLLBACK sem bloco de comando"

  # Numeração de PASSOS sem duplicata (efeito colateral de edição)
  d=$(sed -n '/^## PASSOS/,/^## CRITÉRIOS/p' "$f" | grep -oE '^[0-9]+\.' | sort | uniq -d)
  [ -z "$d" ] || bad "A2.$n.num" "etapa $n: PASSOS com número duplicado: $d"
done
ok A2.z "template conferido nas 16 etapas"

# As 7 de carga-real nascem BLOQUEADA. "Estado:" é mutável — vira CONCLUÍDA ao
# fechar — então não serve para provar o nascimento depois que a esteira anda.
# O impeditivo da ficha (DOCKER-LOCAL.md) é a marca fixa de nascer BLOQUEADA:
# fica escrito na etapa para sempre, também depois de fechada. Só conta se
# aparecer dentro da seção ## IMPEDITIVOS — texto livre em STATUS/ESTADO
# HERDADO pode citar o arquivo sem ser o impeditivo formal da etapa.
has_impeditivo_ficha() {
  sed -n '/^## IMPEDITIVOS/,/^## ESTADO HERDADO/p' "$1" 2>/dev/null | grep -q "DOCKER-LOCAL.md"
}

BLOQ_NASCENTE=0
for n in 05 06 07 08 12 13 13.5 99; do
  f=$(ls "$ROADMAP/$n"-*.md "$ROADMAP/concluidas/$n"-*.md 2>/dev/null | head -1)
  if has_impeditivo_ficha "$f"; then
    BLOQ_NASCENTE=$((BLOQ_NASCENTE + 1))
  else
    bad "A2.i$n" "etapa $n sem o impeditivo da ficha"
  fi
done
if [ "$BLOQ_NASCENTE" -eq 8 ]; then ok A2.b "8 etapas nascem BLOQUEADA (impeditivo da ficha presente)"
else bad A2.b "esperava 8 etapas com o impeditivo da ficha, achei $BLOQ_NASCENTE"; fi

# Nenhuma etapa fora das 7 pode ter herdado o impeditivo por engano
OUTRAS_COM_IMPEDITIVO=0
for f in "$ROADMAP"/[0-9]*.md "$ROADMAP/concluidas"/[0-9]*.md; do
  has_impeditivo_ficha "$f" && OUTRAS_COM_IMPEDITIVO=$((OUTRAS_COM_IMPEDITIVO + 1))
done
if [ "$OUTRAS_COM_IMPEDITIVO" -eq 8 ]; then ok A2.b2 "impeditivo da ficha só nas 8 etapas certas"
else bad A2.b2 "impeditivo da ficha em $OUTRAS_COM_IMPEDITIVO etapas, esperava exatamente 8"; fi

# ============================================================================
sec "3. Decisões travadas (não podem ter se perdido)"
# ============================================================================
# A inversão S06-antes-de-S03: medir sem CAgg é o "antes" honesto
grep_file A3.1 "$(step_file 06)" 'não cria índice nenhum' \
  "etapa 06 declara que NÃO cria índice"
grep_file A3.2 "$(step_file 06)" 'baseline sem otimiza' \
  "etapa 06 explica o porquê do baseline"

# Acionar plano B é decisão de arquitetura, não do agente
grep_file A3.3 "$(step_file 13)" '2h sem CDC' \
  "etapa 13 tem o gatilho do plano B como impeditivo"
grep_file A3.4 "$(step_file 13)" 'PARAR, relatar' \
  "etapa 13: plano B trava e espera decisão"

# status fora do ORDER BY — a pergunta que a banca faz
grep_file A3.5 "$(step_file 11)" 'status.*fora|fora.*status' \
  "etapa 11 justifica status fora do ORDER BY"
grep_file A3.6 "$(step_file 11)" 'POPULATE' \
  "etapa 11 proíbe POPULATE nas MVs"

# Retenção criada e desabilitada — conflito 90d x 12 meses
grep_file A3.7 "$(step_file 08)" 'scheduled *=> *false|scheduled = false' \
  "etapa 08 desabilita a retenção do raw"

# Backfill direto PG->CH, não pelo Kafka
grep_file A3.8 "$(step_file 12)" 'não passa pelo Kafka|direto PG' \
  "etapa 12: backfill não passa pelo Kafka"

# Ordem obrigatória: schema -> backfill -> conector
grep_file A3.9 "$(step_file 11)" 'backfill.*etapa 12|etapa 12' \
  "etapa 11 adia o backfill para a 12"

# ============================================================================
sec "4. Conformidade com o PDF (fonte canônica)"
# ============================================================================
# Requisitos que já foram corrigidos uma vez — se sumirem de novo, é regressão.

# § 3.2 A.5 — as DUAS retenções
grep_file A4.1 "$(step_file 08)" '2 anos' \
  "§3.2 A.5: retenção de 2 anos nos CAggs"

# § 3.2 A.6.c — Q3 com as 3 medidas
grep_file A4.2 "$(step_file 06)" 'taxa de falha' \
  "§3.2 A.6.c: Q3 com taxa de falha"
grep_file A4.3 "$(step_file 06)" 'tempo de liquida|liquidação' \
  "§3.2 A.6.c: Q3 com média de liquidação"

# § 3.2 A.6.b — Q2 com origem E destino
grep_file A4.4 "$(step_file 06)" 'origem e destino|origem.*destino' \
  "§3.2 A.6.b: Q2 com contas de origem e destino"

# § 3.2 B.1 — a terceira tabela do legado
grep_file A4.5 "$(step_file 10)" 'parâmetros de configuração|institution_config' \
  "§3.2 B.1: tabela de configs do legado (origem do Dictionary)"

# § 5.2 A.1 — backup dos TRÊS bancos
grep_file A4.6 "$(step_file 13.5)" 'três bancos|3 bancos' \
  "§5.2 A.1: backup dos três bancos"
grep_file A4.7 "$(step_file 13.5)" 'legado' \
  "§5.2 A.1: legado incluído no backup"
grep_file A4.8 "$(step_file 13.5)" 'lifecycle|cross-region' \
  "§5.2 A.1: destino AWS de produção documentado"

# § 5.2 A.2 — as três contagens do recovery
grep_file A4.9 "$(step_file 13.5)" '3 contagens|três contagens' \
  "§5.2 A.2: recovery com as 3 contagens"

# § 5.2 B.2 — alertas integrados ao CloudWatch/SNS
grep_file A4.10 "$(step_file 15)" 'CloudWatch' \
  "§5.2 B.2: alertas com integração CloudWatch/SNS"

# § 5.2 C — o incidente tem DUAS pistas
grep_file A4.11 "$(step_file 15)" 'security group' \
  "§5.2 C: incidente considera a mudança de security group"

# § 4.2 C.1 — o diagrama completo
grep_file A4.12 "$(step_file 14)" 'SLA' \
  "§4.2 C.1: diagrama com SLAs"
grep_file A4.13 "$(step_file 14)" 'ponto[s]? de falha' \
  "§4.2 C.1: diagrama com pontos de falha"
grep_file A4.14 "$(step_file 14)" 'Hex' \
  "§4.2 C.1: diagrama inclui Hex"
grep_file A4.15 "$(step_file 14)" 'VPC|CloudWatch' \
  "§4.2 C.1: diagrama com serviços AWS"

# § 4.2 B.2 — ref-sync sob migração para Aurora
grep_file A4.16 "$(step_file 14)" 'Aurora' \
  "§4.2 B.2: comportamento do ref-sync sob Aurora"

# § 6 — nomes literais da árvore de entrega
grep_file A4.17 "$(step_file 15)" 'desafio-3/runbook\.md' \
  "§6: nome literal desafio-3/runbook.md"
if grep -rq 'runbook-storage-92' "$ROADMAP"/*.md 2>/dev/null; then
  bad A4.18 "§6: ainda há referência ao nome antigo runbook-storage-92.md"
else ok A4.18 "§6: nome antigo do runbook eliminado"; fi

# § 6.1 — os 7 critérios rastreados.
# Conta só dentro do bloco da tabela de critérios: o mapa requisito→arquivo, logo abaixo,
# também usa linhas "| N |" e contaminaria a contagem. Funciona antes e depois de a
# coluna de evidência ser preenchida pela etapa 99.
C7=$(sed -n '/^## Os 7 critérios/,/^## Mapa/p' "$(step_file 99)" 2>/dev/null \
     | grep -cE '^\| [1-7] \|' || echo 0)
if [ "$C7" -eq 7 ]; then ok A4.19 "§6.1: os 7 critérios de aceitação estão na tabela"
else bad A4.19 "§6.1: esperava 7 critérios na tabela, achei $C7"; fi

# § 7 — duração e os 4 blocos
grep_file A4.20 "$(step_file 99)" '30 a 45|30–45' \
  "§7: duração de 30–45 min registrada"
grep_file A4.21 "$(step_file 99)" 'incidente' \
  "§7: discussão do incidente prevista na apresentação"

# § 3.2 C.5 — ClickHouse servindo aplicação, não só dashboard
grep_file A4.22 "$(step_file 14)" 'API|endpoint' \
  "§3.2 C.5: API servindo aplicação"

# ============================================================================
sec "5. Vault (fonte de arquitetura)"
# ============================================================================
if [ ! -d "$VAULT" ]; then
  skip A5.0 "vault não encontrado em $VAULT — pulando bloco"
else
  want A5.1 "vault/06-Especificacao existe" test -d "$VAULT/06-Especificacao"
  for s in S01-DDL-TimescaleDB S02-Gerador-de-Dados S03-CAggs-e-Politicas S04-Schema-ClickHouse \
           S05-Pipeline-CDC S05-LGPD-Sanitizacao S06-Indices-e-Queries S07-Legado-e-Backup \
           S08-Compose-e-Makefile S10-Conformidade-PDF; do
    want "A5.$s" "S-doc presente: $s" test -f "$VAULT/06-Especificacao/$s.md"
  done

  # Correções aplicadas ao vault — se sumirem, é regressão
  grep_file A5.hex "$VAULT/03-Fluxo-Desenvolvimento/E09-RefSync-ADR.md" 'Hex' \
    "vault: Hex registrado no diagrama (§4.2 C.1)"
  grep_file A5.dur "$VAULT/03-Fluxo-Desenvolvimento/E13-Apresentacao.md" '30 a 45|30–45' \
    "vault: duração 30–45 min corrigida"
  grep_file A5.s10 "$VAULT/06-Especificacao/ESPECIFICACAO.md" 'S10-Conformidade-PDF' \
    "vault: S10 linkado no índice"

  # O vault NÃO pode ter sido copiado para dentro do repo entregue
  want A5.out "vault fora do repo entregue" test ! -d "vault-estudo"
  if ls ./*.pdf >/dev/null 2>&1; then bad A5.pdf "PDF do desafio dentro do repo (não entregável)"
  else ok A5.pdf "PDF fora do repo"; fi
fi

# ============================================================================
sec "6. Higiene e segredos"
# ============================================================================
# Nada de credencial fora do .env.example (que é ambiente local descartável)
LEAK=$(grep -rlEi '(password|senha|secret|token)\s*[:=]\s*["'"'"']?[A-Za-z0-9]{8,}' \
        --include='*.md' --include='*.sh' . 2>/dev/null \
        | grep -v '.env.example' | grep -v 'scripts/tests/audit.sh' || true)
if [ -z "$LEAK" ]; then ok A6.1 "nenhum segredo aparente nos .md/.sh"
else warn A6.1 "revisar possível segredo em: $(echo "$LEAK" | tr '\n' ' ')"; fi

# Nenhum código de aplicação deve existir antes da etapa 01 achatar o repo —
# depois disso (05 seed, etc.) código de aplicação é esperado, não checar mais.
if [ -d "trio-data-challenge" ]; then
  APP=$(find . -name '*.py' -o -name 'Dockerfile' 2>/dev/null | grep -v './trio-data-challenge/' || true)
  if [ -z "$APP" ]; then ok A6.2 "nenhum código de aplicação criado ainda"
  else warn A6.2 "código de aplicação presente antes da hora: $(echo "$APP" | tr '\n' ' ')"; fi
else
  skip A6.2 "repo já achatado (pós-etapa 01) — código de aplicação é esperado"
fi

# run_all.sh precisa continuar cumulativo, com a regra escrita no cabeçalho
grep_file A6.3 scripts/tests/run_all.sh 'ACUMULAÇÃO|cumulativ' \
  "run_all.sh explica a regra de acumulação"

# A ficha bloqueia carga-real enquanto tiver <PREENCHER>
grep_file A6.4 scripts/ambiente/DOCKER-LOCAL.md 'PREENCHER' \
  "ficha de ambiente ainda tem <PREENCHER> (esperado antes de começar)"
grep_file A6.5 CLAUDE.md 'PREENCHER' \
  "CLAUDE.md repete a regra do <PREENCHER>"

# ============================================================================
sec "7. Estado do repositório (pré-etapa 01)"
# ============================================================================
if [ -d "trio-data-challenge" ]; then
  skip A7.1 "aninhamento ainda existe — a etapa 01 vai achatar (esperado agora)"
  want A7.2 "starter tem docker-compose.yml" test -f trio-data-challenge/docker-compose.yml
  want A7.3 "starter tem init/"               test -d trio-data-challenge/init
else
  ok A7.1 "aninhamento já achatado"
  want A7.2 "docker-compose.yml na raiz" test -f docker-compose.yml
  want A7.4 ".gitignore existe"          test -f .gitignore
  grep_file A7.5 .gitignore '^\.env$' ".gitignore cobre .env"
  TOP=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  case "$TOP" in
    *trio-data-challenge) ok A7.6 "git root correto" ;;
    "")  bad A7.6 "sem git init" ;;
    *)   bad A7.6 "git root errado: $TOP" ;;
  esac
  BR=$(git branch --show-current 2>/dev/null || echo "")
  [ "$BR" = "wip/trio-challenge" ] && ok A7.7 "branch wip/trio-challenge" \
    || bad A7.7 "branch atual: '${BR:-nenhuma}' (esperava wip/trio-challenge)"
fi

# ============================================================================
echo
echo "════════════════════════════════════════════════════════════"
printf ' %d pass · \033[31m%d fail\033[0m · \033[33m%d warn\033[0m · %d skip\n' \
  "$PASS_N" "$FAIL_N" "$WARN_N" "$SKIP_N"
echo "════════════════════════════════════════════════════════════"

if [ "$FAIL_N" -gt 0 ]; then
  echo
  echo "IDs que falharam: ${FAILED_IDS[*]}"
  echo "→ Corrigir antes de iniciar a etapa 01."
  exit 1
fi

echo
if [ "$WARN_N" -gt 0 ]; then
  echo "Plano íntegro, com $WARN_N aviso(s) para revisar. Liberado para a etapa 01."
else
  echo "Plano íntegro. Liberado para a etapa 01."
fi
[ "$VERBOSE" = 0 ] && echo "(use --verbose para ver os $PASS_N testes que passaram)"
exit 0
