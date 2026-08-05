# 21 — HIGIENE DE ENTREGA  [local]

> **Etapa criada na revisão de entrega.** Impacto médio, correção fácil, e é a
> **primeira coisa que o avaliador vê ao clonar**. Hoje a raiz mistura
> entregável com andaime de processo: `AUDITORIA-E-REPLANEJAMENTO.md` (475
> linhas), `ETAPA13-ESTADO-PAUSADO.md`, `MEMORIAL_TECNICO.md`, `scripts/roadmap/`
> e — o mais delicado — **`CLAUDE.md` na raiz**, num desafio cujo PDF diz
> explicitamente que *"uso indiscriminado de IA generativa sem revisão crítica
> não é aceitável"*.
> O rastro de processo é genuinamente valioso e **permanece**. O problema é
> nome de arquivo e organização, não conteúdo.

## ORIGEM
Revisão de entrega § 4.6 (artefatos de processo expostos) e § 4.5 última linha (branch `wip/trio-challenge`); PDF § critérios de avaliação (uso de IA generativa); `CLAUDE.md` Seção 8 (regra de git — **esta etapa a modifica, com autorização explícita**)

## IMPEDITIVOS
- [x] **Decisão do usuário sobre a branch** — RESOLVIDO. A autorização explícita para executar esta etapa, que tem o rename no `ESCOPO` e no `PASSO 6`, é a instrução que a Seção 8 exige. Operação local (`git branch -m`), sem remote, reversível por um comando.

## ESTADO HERDADO
Verificado ao fechar as **etapas 20.5 e 20**:
- **Baseline da suíte: 245 pass / 0 fail / 3 skip** (os 3 SKIP são `make`).
- **`docs/` agora tem 6 arquivos**: `SUMARIO-EXECUTIVO`, `CUSTO-AWS`, `DATA-CHAMPIONS`, `SEGURANCA-E-GOVERNANCA`, `HA-E-ROTEIRO-DEMO` e `INVENTARIO-STARTER`. O passo 4 (README com os 6 documentos que importam) tem material — mas **`INVENTARIO-STARTER.md` é andaime**, não entregável: decidir se vai para `docs/processo/`.
- **O clone limpo já foi exercitado nesta etapa** e é o precedente direto do passo 3 da 21: `git clone` para diretório temporário, `docker compose config -q`, conferência dos entregáveis. **Achou um defeito real** (`A2.1` desatualizado) — repetir depois de mover arquivos é obrigatório, não opcional.
- **`audit.sh` `A2.1` agora espera 25 etapas** e o laço confere `17.5` e `20.5`. Mover arquivos para `docs/processo/` **não** muda esse número (ele conta `scripts/roadmap/`), mas mexer em `CLAUDE.md` mexe: o `audit.sh` lê as marcações da Seção 10, e renomear o arquivo para `docs/METODO-DE-EXECUCAO.md` **vai quebrar o audit** se as referências não forem varridas junto. É o passo 3 da 21, e é onde a etapa quebra se for feita no automático.
- **Referências novas a varrer no passo 3**, criadas pelas etapas 17–20: `docs/SUMARIO-EXECUTIVO.md` linka `CUSTO-AWS` e `desafio-1/REPORT.md`; `DATA-CHAMPIONS` linka `SEGURANCA-E-GOVERNANCA`; `HA-E-ROTEIRO-DEMO` linka `desafio-2/PROCEDIMENTOS-PRODUCAO.md` e `CUSTO-AWS`; `REPORT.md` linka `docs/DATA-CHAMPIONS.md`. **São links relativos entre `docs/` e a raiz** — mover qualquer um exige reconferir os dois lados.
- **O README ainda linka `AUDITORIA-E-REPLANEJAMENTO.md`** na seção "Documentos que valem a leitura", ao lado dos entregáveis. É o caso mais visível do gap 4.6.
- **2 defeitos reais foram achados e corrigidos** nas etapas 17.5 e 20.5, ambos registrados no `LOG-EXECUCAO.md` e no `99-validacao-final.md`. **Esse rastro é o ativo de defesa mais forte da entrega** contra "isso é saída de LLM" — a 21 precisa deixá-lo achável, não escondê-lo junto do andaime.
- **`docs/HA-E-ROTEIRO-DEMO.md` § Parte 2 já é o roteiro de apresentação**, com a resposta pronta para abrir o `git log`. O passo 4 da 21 deve linká-lo.
- Ambiente: 11 containers, 10.000.000 nas 3 pontas, legado 480/80.000/50.000/15.

Verificado ao fechar a etapa 16 (segue válido):
- **Raiz do repositório hoje**: `README.md`, `CLAUDE.md` (9,4 KB), `AUDITORIA-E-REPLANEJAMENTO.md` (41 KB / 475 linhas), `MEMORIAL_TECNICO.md` (33 KB), `ETAPA13-ESTADO-PAUSADO.md` (4,5 KB), `PREMISSAS-VERIFICADAS.md` (8,8 KB), `Makefile`, `docker-compose.yml`, `.env.example` — mais `desafio-1/2/3`, `init/`, `scripts/`, `docs/`.
- **`docs/` está quase vazio** (só `INVENTARIO-STARTER.md` e `.gitkeep`) e é o destino natural. As etapas 17–20 adicionam 5 documentos lá — **esta etapa fecha a organização depois deles, não antes**, senão o índice nasce desatualizado.
- **Referências cruzadas existem e vão quebrar se o `git mv` for cego**: o `README.md` linka `AUDITORIA-E-REPLANEJAMENTO.md`; `scripts/tests/audit.sh` lê arquivos de `scripts/roadmap/` e as marcações da Seção 10 do `CLAUDE.md`; vários arquivos de etapa citam `AUDITORIA-E-REPLANEJAMENTO.md § FASE 3`. **Mover sem varrer as referências quebra o `audit.sh`.**
- **`git mv` preserva histórico**; `rm` + `add` não. Todo o valor de "25 commits com histórico limpo" depende de usar `git mv`.
- **`.gitignore` já cobre `.env`, `__pycache__/`, `.venv/`, dumps e `*.raw`.** Há um `.env` real no diretório de trabalho — confirmar que segue ignorado depois de qualquer mexida.
- **Branch única: `wip/trio-challenge`, sem remote**, 25 commits, `master` existe sem nenhum commit (é o default do `git init` deste ambiente). Renomear a branch de trabalho para `main` é operação local e reversível.
- **O histórico é ativo de defesa, não passivo.** Os commits `328e8a9` (CDC investigado e descartado) e `3a9a306` (reconciliação da esteira) mostram investigação e correção de rumo — exatamente o que separa trabalho real de saída de LLM. Nada de reescrever histórico.

## ESCOPO
Faz: consolida o rastro de processo em `docs/`, renomeia o `CLAUDE.md` para um nome que descreve o que ele é, reescreve o README raiz como porta de entrada e resolve a branch de entrega.
Não faz: **não apaga nenhum documento de processo** — o rastro é valioso e permanece; não reescreve histórico de git (`rebase`, `squash`, `filter-branch`); não altera conteúdo técnico de entregável.

## PASSOS
1. **`CLAUDE.md` → `docs/METODO-DE-EXECUCAO.md`** via `git mv`. O conteúdo é legitimamente do autor — escopo travado, arquitetura travada, política de impedimento, regra de teste. O nome é que abre flanco desnecessário. Acrescentar 3–5 linhas de abertura explicando o que o documento é: o contrato de execução que travou escopo e arquitetura antes de escrever código, e como ele foi usado. **Assumir a metodologia é mais forte do que escondê-la** — o PDF condena uso *sem revisão crítica*, e esse arquivo é a prova documental da revisão crítica.
2. **Consolidar o processo em `docs/processo/`** (`git mv`, nunca `rm`): `AUDITORIA-E-REPLANEJAMENTO.md`, `MEMORIAL_TECNICO.md`, `ETAPA13-ESTADO-PAUSADO.md`, `PREMISSAS-VERIFICADAS.md`. Avaliar se `ETAPA13-ESTADO-PAUSADO.md` ainda tem função — a etapa 13 foi descartada e documentada na 13.5 e na auditoria; se for redundante, absorver o conteúdo em vez de manter arquivo órfão.
3. **Varrer e corrigir toda referência aos arquivos movidos.** `README.md`, arquivos de `scripts/roadmap/`, `scripts/tests/audit.sh` e os documentos que citam `AUDITORIA-E-REPLANEJAMENTO.md § FASE 3`. **Rodar `audit.sh` e `run_all.sh` depois** — é aqui que a etapa quebra se for feita no automático.
4. **README raiz como porta de entrada.** Uma seção logo no topo apontando **os 6 documentos que importam**, na ordem de quem lê: `SUMARIO-EXECUTIVO` → `REPORT` → `ADR` → `DATA-CHAMPIONS` → `SEGURANCA-E-GOVERNANCA` → `incident-response`. Abaixo, uma seção separada de processo linkando `docs/processo/` e `docs/METODO-DE-EXECUCAO.md`, com uma linha dizendo o que é. O avaliador precisa distinguir entregável de andaime em **10 segundos**.
5. **`scripts/roadmap/` fica onde está**, mas o README diz o que é: a esteira de execução, 21 etapas com desvio registrado. Escondê-la perderia a melhor evidência de processo real.
6. **Branch de entrega** (só após o impeditivo resolvido): `git branch -m wip/trio-challenge main`. Conferir que `master` vazio não atrapalha e que `git log` na `main` mostra os 25+ commits. **Sem remote, sem push** — segue valendo a Seção 2.
7. **Varredura final de segredo.** `git log -p` atrás de credencial commitada em algum momento e depois removida — remoção em commit posterior não tira do histórico. Se houver, declarar (é senha de ambiente local descartável) em vez de reescrever histórico.
8. **Atualizar a Seção 8 do `METODO-DE-EXECUCAO.md`** registrando a mudança de branch e a autorização explícita que a permitiu. Regra alterada sem registro é regra que ninguém confia.
9. Acrescentar o bloco `# --- 21 higiene-de-entrega ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] Raiz contém **só o `README.md`** como `.md` — teste `21.4`
- [x] `CLAUDE.md` fora da raiz; `docs/METODO-DE-EXECUCAO.md` com a abertura que **assume a metodologia** em vez de escondê-la — testes `21.1`/`21.2`/`21.2b`
- [x] Processo em `docs/processo/` (5 arquivos), movidos com `git mv` — testes `21.3`/`21.3b`
- [x] Nenhuma referência quebrada: `audit.sh` **83 pass / 0 fail**, `run_all.sh` **256 pass / 0 fail**. Duas quebras reais encontradas e corrigidas (ver desvio 2)
- [x] README aponta os **6 documentos**, com o processo em seção separada — testes `21.6`/`21.6b`/`21.10`
- [x] Branch de entrega é **`main`**, com **30 commits** visíveis — testes `21.7`/`01.4`/`A7.7`
- [x] Varredura de segredo feita: `.env` **nunca** commitado; chave privada do MinIO existe no histórico e está **declarada** em `SEGURANCA-E-GOVERNANCA.md` § 3 com o motivo de não reescrever o histórico
- [x] **Nada apagado** — só movido; teste `21.3b` guarda os 3 documentos principais

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 21.1 | local | `! test -f CLAUDE.md` | sai 0 |
| 21.2 | local | `test -f docs/METODO-DE-EXECUCAO.md` | sai 0 |
| 21.3 | local | `test -d docs/processo` | sai 0 |
| 21.4 | local | `ls *.md \| wc -l` | ≤ 1 (só o README na raiz) |
| 21.5 | local | `bash scripts/tests/audit.sh` | 0 fail |
| 21.6 | local | `grep -c 'docs/' README.md` | ≥ 6 (os 6 documentos linkados) |
| 21.7 | local | `git log --oneline \| wc -l` | ≥ 25 (histórico intacto) |
| 21.8 | local | `git branch --show-current` | `main` |
| 21.9 | local | `! git ls-files \| grep -q '^\.env$'` | sai 0 (`.env` fora do versionamento) |
| 21.10 | local | varredura de links quebrados nos `.md` movidos | nenhum caminho inexistente |

## ROLLBACK
```bash
git reset --hard <sha do checkpoint da etapa 20>
git branch -m main wip/trio-challenge
```
> Só movimentação de arquivo e rename de branch — reversível por completo. Nada de
> `rebase`, `squash` ou reescrita de histórico em nenhum passo.

## STATUS
Estado: CONCLUÍDA

Premissas assumidas:
- **Assumir a metodologia é mais forte do que escondê-la.** O preâmbulo de `METODO-DE-EXECUCAO.md` diz abertamente que IA foi usada como ferramenta e mostra o contrato que a governou. O PDF condena uso *sem revisão crítica* — o arquivo é a prova documental da revisão, e o argumento mais forte está na esteira: duas etapas nasceram de defeito achado **medindo**, e uma foi descartada com causa-raiz provada.
- **`git mv`, nunca `rm` + `add`.** Todo o valor de "30 commits com processo real" depende de o histórico atravessar o rename. Nenhum documento de processo foi apagado.
- **Histórico não se reescreve.** A chave privada do MinIO no histórico é de certificado autoassinado local, que não abre nada; `filter-branch` custaria o rastro inteiro do processo para remover risco nulo. Declarado no documento de segurança, com o critério explícito de quando a decisão seria a oposta.
- **`INVENTARIO-STARTER.md` também foi para `docs/processo/`.** Estava em `docs/` desde o começo, mas é andaime — mantê-lo ao lado dos 6 entregáveis contradiria a etapa.

Desvios do plano:
1. **O `audit.sh` precisou de mais que troca de caminho.** O `PASSO 3` previa "varrer referências", mas `A1.10` (limite de 110 linhas) passou a **falhar por motivo legítimo**: o arquivo virou também documento de entrega e ganhou 24 linhas de preâmbulo que não são lidas a cada etapa. Em vez de subir o teto e perder a guarda, o teste passou a medir **só as seções de regra** (`sed` a partir de `## 1. Operação`) — que continuam sendo o que pesa no contexto. Teto do arquivo inteiro subiu para 140; o das regras segue < 110.
2. **Duas referências quebraram de verdade, e só apareceram rodando.** `E1.4` apontava para `PREMISSAS-VERIFICADAS.md` na raiz, e `A7.7`/`01.4` asseriam `wip/trio-challenge`. Nenhuma das duas é achável por leitura — a primeira só falha depois do `git mv`, a segunda só depois do rename. **É a confirmação prática do que o `ESTADO HERDADO` avisava**: esta é a etapa que quebra se for feita no automático.
3. **Referências históricas foram mantidas com o nome antigo, de propósito.** `LOG-EXECUCAO.md`, `99-validacao-final.md` e as etapas em `concluidas/` citam `CLAUDE.md` e `AUDITORIA-E-REPLANEJAMENTO.md` na raiz. **Corrigi-las seria falsificar o registro** — elas descrevem o que era verdade naquele momento. Só referência *viva* (README, `audit.sh`, `run_all.sh`) foi atualizada.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (bloco `# --- 21 higiene-de-entrega ---`, 11 testes)
- [x] run_all.sh sem FAIL — **256 pass, 0 fail, 3 skip**
- [x] ESTADO HERDADO da 99 atualizado
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → registrados em `99-validacao-final.md`
- [x] Commit checkpoint
- [x] Mover pra concluidas/. Marcar [x] na esteira
