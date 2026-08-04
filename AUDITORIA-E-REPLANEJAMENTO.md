# Auditoria e Replanejamento Arquitetural — Trio Data Challenge

**Data:** 2026-08-04 · **Rodada:** auditoria, não implementação · **Nada foi commitado.**

Diagnóstico feito contra o repositório e contra o ambiente Docker **vivo**, não contra os MDs de status.

---

## 0. Sumário executivo

O projeto está **substancialmente melhor do que a sensação de fracasso sugere**. Desafio 1 está praticamente completo e com qualidade de banca. O que travou foi um único ponto — o CDC da etapa 13 — e **a causa-raiz foi encontrada e provada experimentalmente nesta auditoria** (Seção 3).

Três fatos que mudam o plano:

1. **O CDC não está "travado por causa desconhecida".** A premissa que fundamenta o passo 1 da etapa 13 é **factualmente falsa**: `publish_via_partition_root` **não funciona** em hypertable do TimescaleDB. Provado com experimento reversível abaixo. Não é bug do Debezium, não é volume, não é o reseed.
2. **O maior risco do projeto não é técnico, é de escopo.** Faltam **~40% dos requisitos do PDF**, quase todos no Desafio 3 (backup, recovery, runbook, incidente, dashboards) e no Desafio 2 (ADR, diagramas, ref-sync). O tempo gasto perseguindo o CDC é tempo que não foi para requisitos que **valem 20% da nota** e ainda estão em zero.
3. **O `git init` da raiz nunca foi commitado.** O repositório em `Desafio técnico/Trio/` tem 0 commits. Todo o histórico vive em `trio-data-challenge/.git`, branch `wip/trio-challenge`, sem remote. Existe também um diretório fantasma `trio-data-challenge;C` (vazio) — resíduo de comando malformado.

Recomendação central: **abandonar o Debezium** (não por ele ser ruim, mas por ser o caminho errado para hypertable) e adotar o **plano B já previsto em S05**, que reaproveita ~80% do código já escrito e testado. Depois, gastar todo o tempo restante no Desafio 3.

---

## FASE 2 — DIAGNÓSTICO CRÍTICO

### 2.1 Estado real (verificado no ambiente, não nos MDs)

| Componente | Estado | Evidência colhida agora |
|---|---|---|
| TimescaleDB: schema, hypertable, 10M | **Funciona** | `count(*) = 10.000.002` (10M + 2 linhas de teste da etapa 13) |
| CAggs (2), compressão, retenção | **Funciona** | `cagg_volume_hourly`, `cagg_settlement_latency_daily`; jobs 1002 (compressão) e 1007 (retenção, `scheduled=false` por decisão) |
| Q1–Q4 + EXPLAIN antes/depois | **Funciona** | 10 arquivos em `queries/explains/`; `REPORT.md` 284 linhas |
| Gapfill 48h | **Funciona** | `bonus_gapfill_48h.sql` |
| LGPD / sanitização | **Funciona** | `lgpd-sanitization.md` 276 linhas + procedimento testado |
| PostgreSQL legado + bloat + 2 queries | **Funciona** | 50k users, 80k accounts, `n_dead_tup=400.000` |
| Análise Aurora | **Existe, magro** | `migration-analysis.md` — **60 linhas** para um requisito de "1 página" com 4 sub-tópicos |
| ClickHouse: engine, MVs, Dictionary | **Funciona** | `transactions_raw` (ReplacingMergeTree), 2 MVs, `dict_institutions` resolve dado real |
| Backfill 10M PG→CH | **Funciona** | 10.000.000, `FINAL` idêntico, sem duplicata |
| Query Pix 24h vs D-1 sub-segundo | **Funciona** | mediana **8ms** contra alvo de 1000ms |
| **CDC Debezium** | **QUEBRADO** | slot parado em `3/65D24C8`, 5,3 MB de WAL retido; INSERT novo não gera evento |
| **API que serve o ClickHouse** (Desafio 1 C.5) | **NÃO EXISTE** | só `desafio-2/pipeline/consumer/` existe |
| **ref-sync** (Desafio 2 B.1) | **NÃO EXISTE** | `build context` aponta para diretório inexistente |
| **ADR** (Desafio 2 C.2) | **NÃO EXISTE** | |
| **Diagramas** (Desafio 2 C.1) | **NÃO EXISTE** | `desafio-2/diagrams/` só tem `.gitkeep` |
| **Backup dos 3 bancos** (Desafio 3 A.1) | **NÃO EXISTE** | `desafio-3/backup/` só tem `.gitkeep` |
| **Recovery drill** (Desafio 3 A.2) | **NÃO EXISTE** | |
| **Runbook** (Desafio 3 A.3) | **NÃO EXISTE** | |
| **Dashboards Grafana** (Desafio 3 B.1) | **NÃO EXISTE** | só o datasource provisionado; 0 dashboards |
| **Alertas** (Desafio 3 B.2) | **NÃO EXISTE** | |
| **Incidente SEV-1** (Desafio 3 C) | **NÃO EXISTE** | |

### 2.2 Divergências entre MD e realidade

| # | O MD afirma | A realidade é | Gravidade |
|---|---|---|---|
| D1 | Etapa 13: "`publish_via_partition_root = true` funcionou sobre a hypertable" | **Não funcionou.** Provado: com a publication só em `public.transactions`, a decodificação lógica emite **zero** mudanças. O evento que chegou ao tópico veio do **RegexRouter** (a "rede de segurança"), não do `pubviaroot` | **Crítica** — é a premissa que sustenta a etapa inteira |
| D2 | `run_all.sh`: "81 pass / 0 fail / 3 skip" | **77 pass / 4 fail / 3 skip.** FAILs 05.1, 08.4, 08.10, 12.3 — todos causados pelas 2 linhas `DEMO-CDC` deixadas na `transactions` | Alta — a suíte de regressão está vermelha e o status diz que está verde |
| D3 | `MEMORIAL_TECNICO.md`: "Gerado em 2026-08-03 (etapas 01–07 concluídas)" | Etapas 08–12 também fecharam. O memorial **para na 7** e tem 2 respostas `[NÃO REGISTRADO]` | Média — é o documento que a banca lê |
| D4 | Etapa 13, ESTADO HERDADO: "`--profile core` continua quebrado (bug pré-existente)" | Verdadeiro, e **nunca foi corrigido**. `grafana` está em `core`+`full`, mas depende de `prometheus`, que só está em `full` | Alta — é o **critério de aceite nº 1 do PDF** (`docker-compose up -d` sobe sem erros) |
| D5 | `compose`: serviços `ref-sync`, `api`, `backup` declarados com `build:` | Os 3 diretórios **não existem**. `--profile full up` falha no build | Alta |
| D6 | Etapa 13: "id=10000000 era dado real do seed" | Os IDs 20000000–20000352 **são** dado legítimo do seed; só 20000354/355 são sintéticos | Baixa — mas indica que o reseed de 10M pode ter sido desnecessário |

### 2.3 Causa-raiz do travamento do CDC — **provada, não hipótese**

O ETAPA13 lista 4 hipóteses, todas erradas. A causa real:

> **A hypertable do TimescaleDB não é uma tabela particionada nativa do PostgreSQL.**
> Portanto `publish_via_partition_root` não tem sobre o que agir, e escritas em chunks nunca entram na publication.

Prova experimental (executada e **revertida** nesta auditoria):

```
1. relkind da 'transactions'          → 'r'  (tabela comum, NÃO 'p' de partitioned)
2. relispartition do chunk            → 'f'  (NÃO é partição declarativa)
3. INSERT novo → cai em _timescaledb_internal._hyper_1_1424_chunk
4. pg_logical_slot_peek_binary_changes (SEM Debezium no caminho) → 0 mudanças
5. ALTER PUBLICATION ... ADD TABLE <o chunk> ; INSERT
6. peek de novo                        → 6 mudanças  ← a decodificação volta na hora
```

O passo 4 é o que fecha o caso: **sem o Debezium no circuito**, o próprio PostgreSQL não decodifica nada. O problema nunca esteve na JVM, no volume, no reseed ou no decoder. O `jstack` que faltou não teria mostrado nada — não havia nada preso.

Por que o heartbeat enganava: `cdc_heartbeat` é tabela **comum**, entra na publication normalmente. Ela pulsava a cada 10s, o conector ficava `RUNNING`, e isso produzia a aparência de "vivo mas travado". Estava vivo e **corretamente sem nada para emitir**.

Por que "funcionou antes e parou": não funcionou antes. O evento que chegou ao tópico na primeira tentativa passou pelo **RegexRouter**, que estava configurado para capturar `_hyper_\d+_\d+_chunk` — a "rede de segurança" era, na verdade, o **único mecanismo funcionando**. Quando `table.include.list` foi restrito de `public.transactions,_timescaledb_internal.*` para só `public.transactions` (item 3 do ETAPA13, feito para "melhorar performance"), **o único caminho que funcionava foi cortado**. O reseed é coincidência temporal, não causa.

### 2.4 Causa-raiz do problema de **processo** (o que realmente precisa mudar)

A falha técnica acima é sintoma. A causa estrutural é outra:

**Uma premissa não verificada foi promovida a contrato de arquitetura.**

O `CLAUDE.md` § 3 declara: *"Publication manual com `publish_via_partition_root = true`; RegexRouter como rede de segurança"* — e o § 5 (política de impedimento) proíbe divergir de S01–S08 sem travar e esperar. O efeito combinado:

- A premissa entrou como **fato** vindo do vault de estudo, sem nunca ter sido testada contra a versão real do TimescaleDB.
- Quando a realidade divergiu, a estrutura **não permitia questionar a premissa** — só permitia questionar a execução. Por isso as 4 hipóteses do ETAPA13 investigam Debezium, volume, JVM e chunks, e **nenhuma** investiga "e se `pubviaroot` simplesmente não se aplicar aqui?".
- O RegexRouter, rotulado como "redundância proposital", **mascarou** a falha da premissa principal: enquanto ele estava no caminho, tudo parecia funcionar.

Três mudanças de processo:

1. **Premissa de terceiro vira teste antes de virar contrato.** Toda afirmação sobre comportamento de ferramenta (`pubviaroot` funciona em hypertable, `timescaledb_toolkit` está na imagem, `debezium/connect:2.7` existe) precisa de um **teste de 2 minutos** antes de entrar em S-doc. Note que este projeto **já foi mordido 3 vezes pelo mesmo padrão**: toolkit ausente (etapa 08), tag de imagem inexistente (etapa 13), `pubviaroot` (etapa 13). É um padrão, não azar.
2. **Mecanismo de fallback não pode ser silencioso.** O RegexRouter escondeu que o caminho principal estava morto. Fallback precisa **contar**: se ele agiu, isso vira métrica e log de aviso.
3. **Time-box com gatilho automático.** O impeditivo "2h sem CDC → PARAR e aguardar decisão" existia e **funcionou** — foi o que produziu o ETAPA13. Isso deve ser mantido. O que faltou foi, ao parar, **reabrir a premissa** em vez de só listar hipóteses de execução.

### 2.5 Dívida técnica e riscos de dados

| # | Item | Risco | Prioridade |
|---|---|---|---|
| R1 | Slot `trio_cdc_slot` ativo e parado, retendo WAL | **Alto** — WAL cresce indefinidamente; em produção isso enche o disco e derruba o banco. É literalmente o cenário do runbook do Desafio 3 | **P0** |
| R2 | 2 linhas `DEMO-CDC` na `transactions` | Quebra 4 testes; contamina 08.10 e 12.3 | **P0** |
| R3 | `--profile core up` quebrado (`grafana`→`prometheus`) | Falha o **critério nº 1 do PDF**. Um avaliador que rode o comando do README vê erro | **P0** |
| R4 | 3 serviços com `build:` para diretórios inexistentes | `--profile full up` falha | **P0** |
| R5 | `archive_command=pgbackrest` sem pgBackRest instalado | `FATAL: archive command failed (127)` em loop; **WAL nunca é arquivado** → o backup do Desafio 3 não tem base | **P1** |
| R6 | Sem idempotência real no consumidor | `ReplacingMergeTree` dedup por `(ORDER BY, _version)`. Reprocessar o **mesmo** evento é seguro; mas um `UPDATE` que não altere `updated_at` gera versão duplicada indistinguível | **P1** |
| R7 | `op_counts` resetado a cada iteração do laço, mas `buffer` só esvazia no flush | Métrica `pipeline_events_total` **subconta**. Bug real em `main.py:75` | **P2** |
| R8 | `metrics.py` usa prefixo `pipeline_`, teste 13.3 espera `^trio_` | Teste passaria vazio ou falharia | **P2** |
| R9 | `sink.py`: mensagem de erro diz "esgotadas 5 tentativas" mas foram 6 (`[0] + 5 delays`) | Cosmético, mas a banca lê o código | **P3** |
| R10 | RAM Docker 8,3 GB vs ~20 GB que o perfil `full` declara | OOM ao subir tudo | **P1** |
| R11 | `git` da raiz com 0 commits + diretório fantasma `trio-data-challenge;C` | Confusão sobre onde está o repositório de entrega | **P1** |
| R12 | Sem backup **nenhum** hoje | Um `docker volume rm` perde 10M de linhas e ~2h de carga | **P0** |

**R12 é o mais grave e o mais irônico:** o projeto vai ser avaliado em backup e recovery (Desafio 3, 20% da nota) e não tem backup de si mesmo.

---

## FASE 3 — MATRIZ DE RASTREABILIDADE

Uma linha por requisito do PDF. Legenda: **OK** = entregue e verificado · **PARCIAL** = existe mas não atende o texto integral · **FALTA** = inexistente.

### Desafio 1 — Parte A (TimescaleDB)

| # | Requisito (PDF § 3.2 A) | Onde está | Status | Gap |
|---|---|---|---|---|
| A1 | Schema: `transactions`, `accounts`, `reconciliation_events` | `init/timescaledb/01_schema.sql` | **OK** | — |
| A2 | `transactions` como hypertable + chunk interval justificado | idem + `REPORT.md` | **OK** | — |
| A3 | ≥10M transações, 12 meses, distribuição realista | `desafio-1/seed/` | **OK** | 2 linhas de teste a remover |
| A4a | CAgg: volume/valor por tipo, por hora | `04_caggs_policies.sql` | **OK** | — |
| A4b | CAgg: P95/P99 de latência por instituição, por dia | idem | **PARCIAL** | `timescaledb_toolkit` ausente → plano B sem `percentile_agg`. **Documentar explicitamente**, é requisito literal |
| A5 | Retenção 90d raw / 2 anos CAgg / compressão 7d | idem | **PARCIAL** | Retenção criada mas **desabilitada** (job 1007 `scheduled=f`). Justificado, mas precisa estar no REPORT |
| A6 | Q1–Q4 com EXPLAIN antes/depois | `queries/` + `explains/` | **OK** | — |
| A7 | Por query: índices justificados, impacto do particionamento, plano comentado | `REPORT.md` | **OK** | Ponto forte: o índice que **não** melhorou está documentado |
| A8 | `time_bucket_gapfill`/`locf` — série contínua 48h | `bonus_gapfill_48h.sql` | **OK** | — |
| A9 | Sanitização de chunks comprimidos com PII (LGPD) | `lgpd-sanitization.md` | **OK** | Passo de propagação ao CH é "futuro" — fechar agora que o CH existe |

### Desafio 1 — Parte B (PostgreSQL legado)

| # | Requisito (PDF § 3.2 B) | Onde está | Status | Gap |
|---|---|---|---|---|
| B1 | Schema legado (users, contas, configs) + seed | `02_legacy.sql` | **OK** | — |
| B2 | ≥2 queries complexas otimizadas + EXPLAIN | `legacy_q1/q2` + explains | **OK** | — |
| B3 | Doc de 1 página: EC2 vs Aurora vs RDS, critérios, migração, rollback | `migration-analysis.md` | **PARCIAL** | 60 linhas. Verificar se cobre os **4** sub-itens (custo/perf/HA/overhead; DMS/lógica/blue-green; riscos; rollback) |

### Desafio 1 — Parte C (ClickHouse)

| # | Requisito (PDF § 3.2 C) | Onde está | Status | Gap |
|---|---|---|---|---|
| C1 | Schema + engine, ORDER BY, PARTITION BY, codecs justificados | `init/clickhouse/01_schema.sql` | **OK** | — |
| C2a | MV: resumo diário por instituição e tipo (count, sum, avg, p95) | `mv_daily_by_institution` | **OK** | — |
| C2b | MV: funil de status + tempo médio em cada estágio | `mv_status_funnel` | **PARCIAL** | Limitação assumida (sem histórico de transições). Declarar no REPORT |
| C3 | ≥1 Dictionary + uso em query + por que não JOIN | `dict_institutions` | **PARCIAL** | Dictionary existe e resolve; falta o **texto** "quando e por que preferir a JOIN" |
| C4 | Query Grafana Pix 24h vs D-1, sub-segundo | `grafana_pix_24h_vs_d1.sql` | **OK** | 8ms medido |
| C5 | **Cenário: ClickHouse servindo uma aplicação (API → JSON)** | — | **FALTA** | Requisito literal, nada existe |

### Desafio 2

| # | Requisito (PDF § 4.2) | Onde está | Status | Gap |
|---|---|---|---|---|
| 2A1 | Pipeline TS→CH + **justificativa escrita** da abordagem vs alternativas | `pipeline/consumer/` | **PARCIAL** | Código existe e é bom; **o pipeline não funciona** e a justificativa não está escrita |
| 2A2a | Idempotente | `ReplacingMergeTree` + `_version` | **PARCIAL** | Mecanismo correto; depende do pipeline voltar a funcionar |
| 2A2b | Retry, DLQ, logging | `sink.py`, `main.py` | **OK** | Testado antes do travamento |
| 2A2c | Observabilidade: logs estruturados, métricas de lag/throughput | `metrics.py` | **OK** | Bug R7/R8 a corrigir |
| 2A2d | **Demonstrável no docker-compose (rode e funcione)** | — | **FALTA** | **Não funciona hoje.** Critério de aceite do PDF |
| 2A3 | Tratamento de mutação (pending→settled) demonstrado na prática | `demo-mutation.sh` | **PARCIAL** | Script existe e rodou uma vez; hoje não roda |
| 2B1 | Pipeline secundário: legado → Dictionary | — | **FALTA** | `ref-sync` só existe no compose |
| 2B2 | Como o pipeline se comportaria numa migração para Aurora | — | **FALTA** | Texto |
| 2C1 | Diagrama: componentes + AWS + fluxos/SLAs + pontos de falha | `diagrams/` vazio | **FALTA** | |
| 2C2 | ADR 1–2 páginas com as 4 perguntas | — | **FALTA** | |

### Desafio 3

| # | Requisito (PDF § 5.2) | Onde está | Status | Gap |
|---|---|---|---|---|
| 3A1 | Backup dos **3** bancos: tipo, frequência/retenção, script funcional, destino AWS | — | **FALTA** | |
| 3A2 | Recovery drill: simular perda, restaurar, 3 contagens com timestamp | — | **FALTA** | |
| 3A3 | Runbook: storage 92%, sanitizar chunks 6+ meses sem downtime | — | **FALTA** | |
| 3B1 | 4 dashboards (TS, CH, Pipeline, Legado) | 0 dashboards | **FALTA** | |
| 3B2 | ≥5 alertas: métrica, threshold, severidade, ação, CloudWatch/SNS | — | **FALTA** | |
| 3C | Incidente SEV-1: investigação, ≥5 hipóteses, resolução, pós-incidente, comunicação | — | **FALTA** | |

### Critérios de aceitação mínimos (PDF § 6.1)

| # | Critério | Status hoje |
|---|---|---|
| 1 | `docker-compose up -d` sobe tudo sem erros | **FALHA** (R3, R4) |
| 2 | Seed roda e popula com volume relevante | **OK** |
| 3 | Queries do Desafio 1 com EXPLAIN documentado | **OK** |
| 4 | ≥1 pipeline TS→CH end-to-end demonstrável | **FALHA** |
| 5 | ≥1 dashboard Grafana consultando ClickHouse | **FALHA** |
| 6 | Documentação cobre decisões com justificativa | **PARCIAL** |
| 7 | Análise PG→Aurora presente e fundamentada | **PARCIAL** |

**2 de 7 plenamente atendidos.** É esta linha que define se a entrega é aceita.

---

## FASE 4 — NOVA PROPOSTA DE ARQUITETURA

### 4.1 Decisão central: trocar CDC por micro-batch incremental

> **Nota de escopo — o Debezium nunca foi requisito.** O PDF cita Debezium 2 vezes, e nas duas como opcional: § 2.2 diz "sinta-se **livre** para adicionar ferramentas como Kafka, Debezium…"; § 4.2 A.1 lista **4 abordagens** em pé de igualdade — CDC com Debezium/Kafka, replicação lógica nativa, **pipeline custom (script Python, cronjob, micro-batches)** ou outra que se julgue adequada — e cobra apenas: *"justifique por escrito: por que essa abordagem e não as outras? Quais trade-offs?"*
>
> Micro-batch é, portanto, **opção nomeada literalmente pelo PDF**, não plano B. O rótulo "plano B" vem do vault de estudo (S05), não da obra canônica. O requisito real é a **justificativa** — e é nela que o trabalho já feito com Debezium se converte em ativo (§ 4.1.1).

**Descartado: insistir no Debezium.** Existem 3 caminhos para fazer Debezium funcionar sobre hypertable, e os três são ruins aqui:

| Alternativa | Por que foi descartada |
|---|---|
| `ALTER PUBLICATION ADD TABLE` para cada chunk | 338 chunks hoje, **e um novo por dia**. Exige um daemon que adiciona chunks à publication continuamente. Frágil e nada elegante de defender numa banca |
| `FOR ALL TABLES` na publication | Captura `_timescaledb_internal` inteiro, incluindo chunks comprimidos e tabelas de catálogo. Volume de eventos-lixo enorme |
| `wal2json` + parser próprio | Troca a imagem fixada (proibido) e reescreve tudo do zero |

**Escolhido: micro-batch incremental por watermark `updated_at`** — a terceira opção do PDF § 4.2 A.1, escolhida por mérito. Motivos:

1. **Reaproveita ~80% do que já existe e foi testado**: `sink.py`, `metrics.py`, `config.py` inteiros; `transform.py` simplifica (lê linha do Postgres, não envelope Debezium).
2. **Elimina 3 componentes** do caminho crítico: Debezium, Redpanda e o slot de replicação. Com eles saem o risco R1 (WAL retido) e ~3,5 GB de RAM — relevante com 8,3 GB disponíveis (R10).
3. **É a escolha tecnicamente correta aqui**, não a consolação. Para um destino analítico OLAP com freshness de segundos-a-minutos, micro-batch entrega o SLA com uma fração da superfície operacional. O CDC se justificaria se houvesse necessidade de capturar `DELETE` físico ou ordem estrita de eventos — não é o caso (§ 4.1.1).
4. **Idempotência fica mais simples**: janela `[watermark, now())` relida é absorvida pelo `ReplacingMergeTree` via `_version`.

#### 4.1.1 A justificativa escrita — o requisito real do PDF § 4.2 A.1

O PDF não pede uma ferramenta, pede um raciocínio. A tentativa com Debezium **não é tempo perdido: é o insumo da melhor resposta possível** a essa pergunta. O ADR (etapa E6) responde com evidência de primeira mão, não com opinião:

| Abordagem | Por que não | Evidência própria |
|---|---|---|
| **CDC com Debezium/Kafka** | `publish_via_partition_root` não funciona sobre hypertable — ela não é tabela particionada nativa (`relkind='r'`, chunk `relispartition='f'`). Sem isso, escritas em chunk não entram na publication | **Medido**: `pg_logical_slot_peek_binary_changes` sem Debezium no circuito → 0 eventos; adicionando 1 chunk à publication → 6 eventos imediatos |
| ↳ contorno A: chunk na publication via daemon | 338 chunks e +1/dia; exige processo que altera a publication continuamente | Contagem de chunks do ambiente |
| ↳ contorno B: `FOR ALL TABLES` | Captura `_timescaledb_internal` inteiro — chunks comprimidos e catálogo | — |
| ↳ contorno C: `wal2json` + parser | Troca imagem fixada; reescreve o transporte do zero | — |
| **Replicação lógica nativa** | Mesma limitação de raiz: também depende de publication sobre a hypertable | Mesmo experimento acima |
| **Micro-batch por watermark** | **Escolhida.** Atende o SLA de freshness com 3 componentes a menos | — |

Trade-off assumido e declarado: perde `DELETE` físico. Em domínio financeiro transação não se apaga, se estorna (`status='reversed'`) — e o `DELETE` administrativo já é coberto pela trilha LGPD, que é separada por design.

**Isto responde literalmente** *"por que essa abordagem e não as outras? Quais trade-offs?"* — com um experimento reproduzível por trás de cada linha. Sob o critério de 40% "Profundidade Técnica", vale mais do que um pipeline que funciona sem que se saiba explicar por quê.

**Custo assumido e a declarar:** perde `DELETE` físico. Mitigação: em domínio financeiro, transação não se apaga — se estorna (`status='reversed'`). O `DELETE` real é operação administrativa, coberta pelo procedimento LGPD (que já é uma trilha separada, tabela lateral). **Escrever isso no ADR** — vira ponto forte, não fraqueza.

**Manter o Redpanda?** Não no caminho crítico. Mas **manter o compose e o consumidor Debezium no repositório**, marcados como "abordagem avaliada e descartada", com o motivo. Prova profundidade: mostra que a alternativa foi construída, não teorizada.

### 4.2 Fluxo de dados alvo

```
┌──────────────┐                          ┌──────────────┐
│ TimescaleDB  │──(1) micro-batch 10s────▶│  ClickHouse  │
│  transactions│    WHERE updated_at >=   │transactions_ │
│  hypertable  │    watermark - overlap   │     raw      │
└──────────────┘                          │(Replacing    │
       │                                  │  MergeTree)  │
       │ pgBackRest (WAL + full)                 │
       ▼                                         │ MV (2)
   ┌────────┐                             ┌──────▼───────┐
   │ MinIO  │◀──clickhouse-backup─────────│ daily_by_inst│
   │  (S3)  │                             │ status_funnel│
   └────────┘                             └──────┬───────┘
                                                 │
┌──────────────┐                                 │
│ PG Legado    │──(3) ref-sync 5min──▶ dict_institutions
│ institutions │                                 │
└──────────────┘                                 │
       │                                   ┌─────┴──────┐
       │                                   ▼            ▼
       └──── pgBackRest ──▶ MinIO     ┌────────┐  ┌─────────┐
                                      │Grafana │  │ API     │
                                      │4 dashs │  │ FastAPI │
                                      └────────┘  └─────────┘
                                           ▲            ▲
                                      Prometheus   (Desafio 1 C5)
                                      (métricas do pipeline)
```

Responsabilidades:

| Componente | Responsabilidade | SLA alvo |
|---|---|---|
| `sync-worker` (novo, substitui cdc-consumer) | Ler janela incremental do TS, escrever no CH, publicar métricas | freshness < 30s |
| `ref-sync` (novo) | Legado → `dict_institutions`, ciclo 5 min | freshness < 5 min |
| `api` (novo) | Endpoints JSON sobre o CH | p95 < 200ms |
| `backup` (novo) | pgBackRest (2 stanzas) + clickhouse-backup → MinIO | RPO 15 min / RTO 30 min |
| Prometheus + Grafana | 4 dashboards + 6 alertas | — |

### 4.3 Contrato de dados do sync-worker

```
watermark:  tabela sync_state(source text PK, last_updated_at timestamptz, last_run_at, rows_synced)
janela:     [last_updated_at - overlap, now())   -- overlap = 30s, cobre clock skew e commit tardio
ordenação:  ORDER BY updated_at, id              -- determinística, permite retomar no meio
lote:       LIMIT 50.000 por ciclo               -- teto de memória previsível
avanço:     só grava o watermark DEPOIS do INSERT no CH confirmar
```

**A regra que garante a corretude:** o watermark avança **depois** da escrita, nunca antes. Falha no meio → próxima execução relê a janela → `ReplacingMergeTree` deduplica por `_version`. É at-least-once no transporte e effectively-once no resultado.

**Pré-requisito a verificar antes de escrever o worker** (aplicando a lição da Seção 2.4): confirmar que o trigger de `updated_at` da etapa 04 realmente dispara em **todo** UPDATE. Se não disparar, o watermark perde mudanças silenciosamente — pior falha possível. **Isto é um teste de 2 minutos e vem antes do código.**

### 4.4 O que se aproveita e o que se reescreve

| Artefato | Decisão | Justificativa |
|---|---|---|
| `sink.py`, `metrics.py`, `config.py` | **Aproveita** | Retry, DLQ e métricas independem da origem |
| `transform.py` | **Simplifica** | Sai o parsing do envelope Debezium; entra mapeamento de linha do psycopg |
| `main.py` | **Reescreve** | Laço de consumo Kafka → laço de polling com watermark |
| `demo-mutation.sh` | **Aproveita, ajusta espera** | A demonstração continua válida: UPDATE no TS → aparece no CH |
| Serviços `debezium`/`redpanda` no compose | **Move para profile `cdc-experimento`** | Mantém a evidência sem poluir o caminho principal |
| Conector + publication + slot | **Remove** | Elimina R1 |
| `init/clickhouse/01_schema.sql` | **Aproveita intacto** | Schema está correto e validado |
| Todo o Desafio 1 | **Aproveita intacto** | Nada a reescrever |

**Sobre manter algo ruim porque já está pronto:** o único candidato é o consumidor Debezium. O código é bom, mas o caminho está morto — mantê-lo no fluxo principal custaria mais um dia de depuração de um problema que **já sabemos ser insolúvel sem trocar o desenho**. Vai para o repositório como artefato de decisão, não como código de produção.

### 4.5 Erro, reprocessamento e observabilidade

| Cenário | Comportamento |
|---|---|
| ClickHouse fora | Retry 1-2-4-8-16s. Esgotou → não avança watermark, dorme, tenta de novo. Nada se perde |
| TimescaleDB fora | Mesmo tratamento; watermark parado |
| Linha malformada | DLQ (arquivo/tabela) + segue. Nunca derruba o ciclo |
| Reprocessar período | `sync_state` recuado manualmente → releitura → dedup por `_version` |
| Reconstrução total | `scripts/backfill-clickhouse.sh` (já existe e funciona) |

Métricas (corrigindo R8 — **prefixo único, alinhado ao teste**):
`sync_last_success_timestamp` (a que detecta o SEV-1), `sync_lag_seconds`, `sync_rows_written_total`, `sync_errors_total{type}`, `sync_batch_duration_seconds`, `sync_watermark_timestamp`.

### 4.6 Roadmap — testes cumulativos

Cada etapa roda **todos** os blocos anteriores do `run_all.sh`. Nenhuma fecha com FAIL.

| Etapa | Entrega | Critérios de aceite |
|---|---|---|
| **E0 — Estabilização** *(2h, P0)* | Backup de tudo (§5). Remover slot/conector/publication. Remover as 2 linhas `DEMO-CDC`. Corrigir `grafana`→`prometheus`. Criar os 3 diretórios de build faltantes. Limpar `trio-data-challenge;C`. Commitar tudo que está solto | `run_all.sh` **0 FAIL**; `docker compose --profile core up -d` sobe limpo; `pg_replication_slots` vazio; `git status` limpo |
| **E1 — Verificação de premissas** *(1h)* | Testar `updated_at` em UPDATE; testar `clickhouse-backup` na imagem; testar `pgbackrest` na imagem. Registrar em `PREMISSAS-VERIFICADAS.md` | Cada premissa com comando + saída real. **Nenhuma linha de código antes disto** |
| **E2 — sync-worker** *(4h)* | `sync_state`, worker, compose, métricas | UPDATE no TS aparece no CH em <30s; matar o worker no meio e religar não duplica (`count() FINAL` estável); DLQ recebe malformado; métricas respondem. **+ E0/E1** |
| **E3 — ref-sync + API** *(3h)* | `ref-sync` (5 min) e `api` FastAPI. Fecha **Desafio 1 C5** e **Desafio 2 B1** | UPDATE no legado aparece no `dictGet` no ciclo seguinte; 3 endpoints 200 com `query_ms`; cache comprovado. **+ E0–E2** |
| **E4 — Backup e recovery** *(5h, maior peso)* | pgBackRest 2 stanzas → MinIO; `clickhouse-backup`; `restore-drill.sh`; `desafio-3/backup/README.md` com os 4 itens × 3 bancos | `pgbackrest check` OK nas 2 stanzas; drill imprime **3 contagens com timestamp**; `sum(amount)` idêntico; **RTO/RPO medidos com número** |
| **E5 — Observabilidade** *(4h)* | 4 dashboards + 6 alertas com os 5 campos + CloudWatch/SNS | 4 dashboards carregam dado real; 6 alertas provisionados; `alertas.md` com CloudWatch/SNS por alerta |
| **E6 — Documentos** *(5h)* | ADR (4 perguntas), diagramas (componentes+AWS+SLAs+falhas), `runbook.md`, `incident-response.md` (≥5 hipóteses), `migration-analysis` expandido, "Dictionary vs JOIN" | Cada doc bate item a item com o texto do PDF. Diagramas renderizam |
| **E7 — Validação final** *(3h)* | Sequência do zero cronometrada; README raiz; REPORT consolidado; MEMORIAL atualizado; roteiro da apresentação | Os **7 critérios do PDF § 6.1** com evidência real; `run_all.sh` 0 FAIL |

**Ordem inegociável: E0 e E1 antes de qualquer código.** É a correção direta da causa-raiz da Seção 2.4.

**Se o tempo apertar, corte nesta ordem:** E3 (API é 1 requisito) → parte de E5 (2 dashboards em vez de 4). **Nunca corte E4** — backup/recovery vale 20% e hoje está em zero.

---

## FASE 5 — POLÍTICA DE BACKUP E CHECKPOINT

Desenhada contra o erro concreto da Seção 2.4: um `DELETE` de 3 linhas virou reseed de 10M porque **não havia ponto de restauração**.

### 5.1 Regra

> **Antes de cada etapa e antes de toda operação destrutiva, existe um ponto de restauração testado.**

Operação destrutiva = `DELETE`, `UPDATE` sem `WHERE` restrito, `TRUNCATE`, `DROP`, `ALTER` de schema, `docker compose down -v`, `docker volume rm`, reseed, `pg_drop_replication_slot`.

### 5.2 O que é copiado

| Nível | Conteúdo | Ferramenta | Quando | Retenção |
|---|---|---|---|---|
| **N1 — Código** | Repositório | `git commit` + `git tag` | Início e fim de cada etapa | Permanente |
| **N2 — Dado quente** | Volumes Docker dos 3 bancos | `docker run --rm -v <vol>:/src -v <dir>:/bkp alpine tar czf` com containers **parados** | Antes de cada etapa e de toda operação destrutiva | 3 mais recentes + 1 por etapa |
| **N3 — Lógico** | `pg_dump -Fc` (2 PGs) + `clickhouse-backup` | scripts | Diário e antes de E4 | 7 dias |
| **N4 — Produção (escrito)** | pgBackRest → S3, lifecycle, cross-region | doc | — | Documento do Desafio 3 |

### 5.3 Nomenclatura

```
backups/
  E<NN>-<slug>/<AAAA-MM-DDTHHMM>/
      timescaledb_data.tar.gz
      clickhouse_data.tar.gz
      postgres_legado_data.tar.gz
      MANIFEST.txt        # commit, contagens, tamanhos, checksums
      RESTORE.md          # comando exato de restauração deste snapshot
```

`MANIFEST.txt` grava as contagens **no momento do backup** — é o que permite verificar que a restauração deu certo sem depender de memória.

Local: **fora do OneDrive** (sincronização durante escrita corrompe tarball). Sugestão: `C:\trio-backups\`.

### 5.4 Restauração — testada, não presumida

Backup nunca restaurado não conta. Protocolo:

```
1. Parar containers dos bancos
2. docker volume rm <volume>  &&  docker volume create <volume>
3. tar xzf <snapshot> para dentro do volume novo
4. Subir e conferir as 3 contagens contra o MANIFEST.txt
5. Registrar o tempo → é o RTO real, número que o Desafio 3 exige
```

**Este drill é executado uma vez em E0** (sobre uma cópia, não sobre o dado principal). Se falhar, a política está errada e se corrige antes de qualquer etapa. O tempo medido aqui **alimenta diretamente o requisito 3A2** — o mesmo trabalho serve para duas coisas.

### 5.5 Onde entra na esteira

`CLAUDE.md` § 9 (checklist de fechamento) ganha **um passo no início**:

```
0. Snapshot N1+N2 criado e MANIFEST.txt escrito   ← NOVO, bloqueia a etapa
1. Critérios atendidos
2. Testes no run_all.sh
...
```

E o § 5 (política de impedimento) ganha uma linha:

```
Trava e espera: ... QUALQUER operação destrutiva SEM snapshot N2 das últimas 24h.
```

Automatizar como `make checkpoint ETAPA=E2` — uma decisão que depende de disciplina humana falha; uma que depende de um alvo de Makefile, não.

---

## Premissas assumidas

1. **O escopo "somente metadado quantitativo (tempo/teclas/cliques por usuário/tela/app)" do briefing não pertence a este projeto.** Nada no PDF, no repositório ou no vault trata de telemetria de uso. Segui o escopo real: transações financeiras. **Se essa linha era intencional, ela muda tudo — me avise.**
2. Prazo de 7 dias já consumiu ~2 dias. O roadmap cabe em ~27h de trabalho efetivo.
3. AWS permanece documento escrito, nunca executado (`CLAUDE.md` § 2).
4. Sem remote git, entrega por zip ou repositório local.
5. As 2 linhas `DEMO-CDC` podem ser removidas — são sintéticas, criadas pela etapa 13, nunca propagadas.
6. Manter o Debezium no repositório como artefato de decisão agrega mais do que remove.

## Perguntas que precisam da sua resposta

| # | Pergunta | Por que trava |
|---|---|---|
| **Q1** | **Confirma a troca de Debezium por micro-batch?** | Muda arquitetura — `CLAUDE.md` § 5 exige sua decisão. **Não há risco de escopo**: o PDF § 4.2 A.1 lista micro-batch como opção de primeira classe; Debezium nunca foi requisito (§ 4.1). O que o PDF cobra é a justificativa, e ela fica mais forte com o experimento em mãos |
| **Q2** | Quanto tempo real ainda resta? | Define se E3 e metade de E5 entram ou são cortados |
| **Q3** | Posso remover slot, conector e publication? | Operação destrutiva. **Recomendo forte**: o slot retendo WAL é o risco P0 vivo |
| **Q4** | Aceita `C:\trio-backups\` fora do OneDrive? | Precisa de espaço em disco (~5–8 GB) |
| **Q5** | Trocar a imagem do TimescaleDB por uma com `timescaledb_toolkit` para atender A4b (P95/P99) literalmente? | `CLAUDE.md` § 2 proíbe trocar imagem. Requisito literal do PDF vs regra do projeto — **o PDF é canônico, mas a decisão é sua** |
| **Q6** | A linha do briefing sobre "metadado quantitativo" (premissa 1) foi engano? | Se não foi, o diagnóstico inteiro muda de alvo |

---

## O que eu faria nas próximas 2 horas

1. Snapshot N2 dos 3 volumes + drill de restauração (§5.4).
2. Commitar o que está solto (consumer, demo-mutation, ETAPA13, compose).
3. Remover slot/conector/publication → mata o risco P0.
4. Remover as 2 linhas `DEMO-CDC` → `run_all.sh` volta a 0 FAIL.
5. Corrigir `grafana`→`prometheus` → critério nº 1 do PDF volta a passar.

Só depois disso, código novo.
