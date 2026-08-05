# 17 — CAMADA EXECUTIVA E CUSTO  [local]

> **Etapa criada na revisão de entrega.** Existe porque o repositório fala com
> engenheiros e a banca é de **audiência mista** (PDF § 7). Há ~2.900 linhas de
> markdown técnico e nenhum documento de 1 página que responda "o que foi
> construído, quanto custa, quais os riscos, o que vem nos próximos 90 dias".
> O PDF avalia liderança técnica, não só profundidade técnica.

## ORIGEM
Revisão de entrega § 4.1 (camada executiva ausente) e § 4.2 (custo em AWS ausente); PDF § 7 "Apresentação Técnica" (audiência mista: engenharia + liderança); `desafio-1/migration-analysis.md` § Aurora vs RDS (hoje para em "~20–30% acima do RDS"); `desafio-2/ADR.md` § MSK adiado

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado ao fechar a etapa 16:
- **Números medidos disponíveis para reaproveitar, todos com evidência**: Q1 12.115 ms → 23 ms (**521×**), Q3 via CAgg **383×**, compressão **5,5×**, query do painel Grafana **12 ms** contra alvo de 1000 ms, RTO **22 s**, freshness do pipeline **~10 s**, Dictionary × JOIN **0,018 s × 0,054 s**. Fonte: `desafio-1/REPORT.md` e `MEDICOES.md`. **Nenhum número novo precisa ser medido nesta etapa** — ela consolida, não mede.
- **`migration-analysis.md` já tem 210 linhas** cobrindo os 4 sub-itens de B3 (EC2 vs Aurora vs RDS, estratégia de migração, riscos, rollback), mas **sem um único valor em dólar**. O texto atual diz "~20–30% acima do RDS" e para aí — é exatamente o ponto que a revisão cobra.
- **`docs/` está praticamente vazio**: só `INVENTARIO-STARTER.md` (2 KB) e `.gitkeep`. Não há colisão de nome para nenhum documento novo.
- **A recomendação AWS já está escrita e é o insumo do TCO**: Aurora PostgreSQL, MSK (deliberadamente adiado no ADR), Fargate, PrivateLink, Managed Grafana, S3 multi-tier. Cada uma aparece em `migration-analysis.md` ou no `ADR.md` — o custo é o que falta, não a decisão.
- **Limitações assumidas já catalogadas** em `99-validacao-final.md` § Limitações assumidas (8 linhas) — insumo direto da seção de riscos do sumário.
- `run_all.sh`: blocos 01–16, **171 pass / 0 fail / 3 skip**.

## ESCOPO
Faz: cria a camada de leitura executiva que hoje não existe — um sumário de 1 página e uma estimativa de TCO em dólar para os dois cenários (atual e 10×).
Não faz: não provisiona nada na AWS (Seção 2 do `CLAUDE.md`); não remede nada — todo número técnico vem de medição já registrada; não reabre a recomendação de arquitetura, só a precifica.

## PASSOS
1. **`docs/SUMARIO-EXECUTIVO.md`, máximo 1 página.** Quatro blocos, nessa ordem: (a) **o que foi construído** em 3–5 linhas; (b) **os 5 números que importam** — ganho de query, compressão, freshness do pipeline, RTO, custo mensal estimado; (c) **3 riscos com dono e mitigação** — nó único de ClickHouse sem HA, pipeline sem teste de saturação, PII sem trilha de auditoria de leitura; (d) **roadmap 30/60/90**. Sem jargão que exija o REPORT para entender. Se passar de 1 página impressa, cortar — o limite é o produto.
2. **`docs/CUSTO-AWS.md` — TCO estimado.** Tabela por serviço em USD/mês, com a **premissa de dimensionamento explícita ao lado de cada linha** (classe de instância, GB, IOPS, horas). Dois cenários: **atual (10M transações/mês)** e **10× (100M/mês)**. Ordem de grandeza fundamentada basta — o que não pode faltar é a premissa que gerou o número.
3. **Aurora vs RDS em dólar.** Substituir "~20–30% acima do RDS" em `migration-analysis.md` por valores absolutos nos dois cenários, mantendo o percentual como leitura derivada. Declarar a data da tabela de preços e a região usada (`us-east-1`), porque preço muda e número sem data envelhece mal.
4. **Custo do MSK que foi adiado.** O `ADR.md` adia o MSK sem dizer o que ele custaria. Precificar o menor cluster viável em produção e registrar no `CUSTO-AWS.md` como "custo evitado pela decisão de micro-batch" — transforma a decisão de arquitetura em número defensável.
5. **Custo do que já roda hoje.** Incluir o Timescale Cloud (ou equivalente gerenciado) na comparação. A pergunta "quanto o legado já consome hoje" é a que dá base de comparação ao TCO; sem ela a tabela flutua.
6. **Ligar a camada executiva ao README.** O `README.md` raiz passa a abrir com um link para o `SUMARIO-EXECUTIVO.md` **antes** da seção Quick Start — quem lê 1 minuto precisa achar o documento de 1 minuto primeiro.
7. Acrescentar o bloco `# --- 17 camada-executiva-e-custo ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] `docs/SUMARIO-EXECUTIVO.md` existe, cabe em 1 página (**69 linhas**) e tem os 4 blocos — testes `17.1`–`17.4`
- [x] `docs/CUSTO-AWS.md` tem valor em USD/mês por serviço, nos 2 cenários, com premissa de dimensionamento ao lado de cada linha — **A ≈ $844/mês, B ≈ $2.677** (+$620 se a fila for acionada). Testes `17.5`/`17.6`/`17.8`
- [x] `migration-analysis.md` compara Aurora e RDS em **dólar** — e a comparação **inverte de sinal** entre os cenários (+10% em A, −17% em B). Região `us-east-1` e data (ago/2026) declaradas. Testes `17.9`/`17.10`
- [x] Custo do MSK adiado precificado: **$620/mês (~$7.400/ano)**, nomeado como custo evitado — teste `17.7`
- [x] Base de comparação presente: Timescale Cloud $400–500 + ClickHouse Cloud $350–600 — teste `17.12`
- [x] `README.md` linka o sumário acima do Quick Start — teste `17.11`
- [x] Nenhum número técnico inventado — 521×, 5,0×, ~10 s, 22 s/60 s conferidos no `REPORT.md`, `ADR.md` e `backup/README.md`; custo declarado como estimativa com premissa exposta

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 17.1 | local | `test -f docs/SUMARIO-EXECUTIVO.md` | sai 0 |
| 17.2 | local | `wc -l < docs/SUMARIO-EXECUTIVO.md` | ≤ 80 (1 página real) |
| 17.3 | local | `grep -ci '30/60/90\|30 dias' docs/SUMARIO-EXECUTIVO.md` | ≥ 1 |
| 17.4 | local | `grep -ci 'risco' docs/SUMARIO-EXECUTIVO.md` | ≥ 3 |
| 17.5 | local | `test -f docs/CUSTO-AWS.md` | sai 0 |
| 17.6 | local | `grep -c 'USD\|\$' docs/CUSTO-AWS.md` | ≥ 10 (tabela, não menção solta) |
| 17.7 | local | `grep -ci 'msk' docs/CUSTO-AWS.md` | ≥ 1 |
| 17.8 | local | `grep -ci '10×\|10x\|100M\|100 M' docs/CUSTO-AWS.md` | ≥ 1 (cenário de escala) |
| 17.9 | local | `grep -c 'USD\|\$' desafio-1/migration-analysis.md` | ≥ 4 (Aurora vs RDS em dólar) |
| 17.10 | local | `grep -ci 'us-east-1' docs/CUSTO-AWS.md` | ≥ 1 (região declarada) |
| 17.11 | local | `grep -ci 'SUMARIO-EXECUTIVO' README.md` | ≥ 1 |

## ROLLBACK
```bash
rm -f docs/SUMARIO-EXECUTIVO.md docs/CUSTO-AWS.md
git checkout -- README.md desafio-1/migration-analysis.md
```
> Etapa 100% documental. Nenhum container tocado, nenhum dado movido.

## STATUS
Estado: CONCLUÍDA

Premissas assumidas:
- **Preço de tabela pública, sem desconto de contrato.** `us-east-1`, ago/2026, sem Savings Plans nem Reserved Instances. Reserva de 1 ano cortaria ~30% do compute, e foi deixada **deliberadamente fora**: comprometer capacidade antes de medir o regime real é justamente como se erra dimensionamento. A premissa está escrita no documento, não só aqui.
- **Ordem de grandeza é o produto, não precisão de centavo.** O requisito é sobreviver à pergunta "quanto dá por mês" numa aprovação de orçamento. Cada linha carrega a premissa de dimensionamento ao lado porque **é a premissa que se discute** — o valor é consequência dela e recalcula junto quando ela muda.
- **Nenhuma medição nova.** Todo número técnico do sumário vem de medição registrada (`REPORT.md`, `ADR.md`, `backup/README.md`). A etapa consolida e traduz; não mede.
- **Os 3 riscos do sumário são os que as etapas 18–20 fecham** — HA do ClickHouse (20), saturação do pipeline (20), auditoria de PII (19). O roadmap 30/60/90 é a esteira restante vista de cima, não uma lista nova.

Desvios do plano:
1. **A comparação Aurora × RDS inverteu o sinal, e isso mudou a justificativa da recomendação.** O passo 3 previa "substituir o percentual por valores absolutos", assumindo que o absoluto confirmaria o "~20–30% acima do RDS". Não confirmou: no cenário atual o Aurora custa **+$26/mês (+10%)** e no cenário 10× custa **−$170/mês (−17%)**. O texto antigo era verdade por vCPU e falso como conta mensal — o Serverless v2 escala para baixo em ocioso, o RDS Multi-AZ provisiona para o pico 24/7. A recomendação de Aurora **foi mantida**, mas a ressalva do documento passou a dizer que ela se paga por HA e reader endpoint, **não por preço no volume atual**. Vender Aurora como economia hoje seria falso.
2. **A âncora do gerenciado enfraquece a tese do autogerido, e entrou assim mesmo.** Timescale Cloud ($400–500) + ClickHouse Cloud ($350–600) somam ≈$750–1.100 contra os ≈$844 da arquitetura proposta: **não há economia relevante em autogerir neste volume**. Omitir a linha deixaria o TCO sem base de comparação; incluí-la responde à pergunta "quanto já se paga hoje" com um número que não favorece a proposta. Mesmo espírito do "índice que não melhorou" (etapa 07) e do empate do Dictionary em `GROUP BY` (etapa 16).
3. **Baseline da suíte estava errado desde a etapa 16.** O ESTADO HERDADO registrava `171 pass`, mas a suíte completa com o ambiente inteiro de pé dá **174** (155 numerados + 34 do bloco E da 13.5, menos os 3 SKIP de `make`). O 171 foi medido com parte dos testes de carga-real em SKIP. Não é regressão nem defeito — é baseline desatualizado, corrigido aqui para **186 pass / 0 fail / 3 skip**.
4. **Compressão corrigida de 5,5× para 5,0×.** O ESTADO HERDADO desta etapa trazia 5,5×; o valor medido no `REPORT.md` é **5,0×** no total (23,5× só na tabela — os 1.484 MB de índice puxam o total para baixo). Corrigido antes de publicar: número de documento executivo é o que a banca cita de volta.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (bloco `# --- 17 camada-executiva-e-custo ---`, 12 testes)
- [x] run_all.sh sem FAIL — **186 pass, 0 fail, 3 skip** (os 3 SKIP são `make` ausente neste Windows)
- [x] ESTADO HERDADO da próxima (18) preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → 4 registrados acima; os desvios 1 e 2 vão para `99-validacao-final.md`
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
