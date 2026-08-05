# Memorial Técnico — Trio Data Challenge

**Projeto:** Desafio Técnico — Engenheiro de Dados Sênior, Trio Grupo Financeiro
**Stack:** TimescaleDB (pg16), PostgreSQL 16, ClickHouse 24.8, Redpanda v24.2.7, Debezium 2.7, Grafana 11.3.0, Prometheus v2.54.1, MinIO, Python 3.12 (psycopg 3.2.3, numpy 2.1.3), Docker Compose
**Objetivo:** Montar ambiente local com 3 bancos, carregar 10M de transações sintéticas, medir e otimizar queries com evidência de `EXPLAIN` antes/depois, e montar pipeline CDC TimescaleDB → ClickHouse.
**Gerado em:** 2026-08-03 (etapas 01–07) · **Atualizado em:** 2026-08-04 (etapas 08–13 e E0–E4)

Registro de decisões de desenvolvimento. Não é documentação de uso — para isso, ver `README.md` e `make help`.

---

## 1. baseline-e-estrutura

**Entregue:** Repo achatado (aninhamento duplicado removido), `git init` + branch `wip/trio-challenge`, `.gitignore`, árvore de diretórios do PDF § 6, `docs/INVENTARIO-STARTER.md`.
**Desafio:** O starter vinha aninhado (`trio-data-challenge/trio-data-challenge/`) e o git root apontava para `GitHub/`, não para o projeto.
**Solução:** Mover conteúdo um nível acima, `git init` na raiz correta, criar as 8 pastas do PDF com `.gitkeep`.
**Por quê:** Sem git próprio, todo commit do projeto poluiria o repositório pessoal do usuário.
**Trade-off:** Nenhum relevante. Etapa puramente estrutural.
**Evidência:** commit `1ee1640`; testes 01.1–01.7 em `scripts/tests/run_all.sh`.
**Status:** ok

---

## 2. compose-evoluido

**Entregue:** `docker-compose.yml` com 15 serviços (10 imagem + 5 build local), perfis `core`/`full`, healthchecks com `start_period`, cadeia `depends_on: service_healthy`, MinIO na 9002.
**Desafio:** 5 serviços são `build:` local sem Dockerfile ainda (criados nas etapas 05/13/14/15), então `--profile core up -d` completo não subia.
**Solução:** Validado o subconjunto de 4 serviços com imagem pronta (timescaledb, postgres-legado, clickhouse, grafana) — os 3 com healthcheck ficaram `healthy` sem intervenção.
**Por quê:** Alternativa considerada e descartada: criar Dockerfiles stub só para o `up` passar. Foge do escopo da etapa ("não escreve código de aplicação") e criaria artefato falso.
**Trade-off:** O critério "todos healthy" ficou parcialmente validado até as etapas 05/14 existirem.
**Evidência:** commit `9d35e05`; testes 02.1–02.6.
**Status:** parcial — validação completa do perfil `core` depende das etapas 05/14.

---

## 3. makefile-e-healthcheck

**Entregue:** `Makefile` com 23 alvos (`help` default, auto-documentado), `scripts/wait-healthy.sh`, `scripts/health-check.sh`.
**Desafio:** `make` não existe neste Windows; `winget install GnuWin32.Make` falhou com `InternetOpenUrl() failed` (download do Sourceforge).
**Solução:** Validação via container Docker auxiliar (`docker:27-cli` + `make` instalado on-the-fly, socket montado, `COMPOSE_PROJECT_NAME` explícito). `run_all.sh` faz SKIP nos 3 testes que dependem de `make` quando ele está ausente do PATH.
**Por quê:** Alternativa descartada: validar só a sintaxe do Makefile sem executar. Provaria menos — não pegaria erro de expansão de variável nem de alvo quebrado.
**Trade-off:** Os testes 03.1/03.2/03.5 dão SKIP nesta máquina; passam em ambiente com `make` instalado.
**Evidência:** commit `b5eddd6`; `scripts/tests/run_all.sh` (função `has_make`).
**Status:** ok

---

## 4. schema-timescaledb

**Entregue:** `init/timescaledb/01_schema.sql` (5 ENUMs, `accounts`, `transactions` hypertable 1d + trigger `updated_at`, `reconciliation_events` hypertable 7d + coluna gerada `difference`), `02_seed_marker.sql`, cópia canônica em `desafio-1/schemas/`.
**Desafio:** Primeira versão do `seed_control` usou colunas inventadas (`completed_at`/`row_count`) em vez das literais da especificação (`started_at`/`finished_at`/`total_rows`, constraint `single_row`).
**Solução:** Detectado ao ler a ORIGEM da etapa 05 antes de fechar a 04. Corrigido antes do commit — nenhum artefato errado foi versionado.
**Por quê:** A tabela é contrato entre etapas: a 05 lê `finished_at` para decidir idempotência. Divergir quebraria a etapa seguinte silenciosamente.
**Trade-off:** Volume do timescaledb recriado 2× (o `init/` só roda na criação do container). Sem perda — nenhum seed havia rodado.
**Evidência:** commit `7e6dde2`; testes 04.1–04.6.
**Status:** ok

---

## 5. seed-10m

**Entregue:** Gerador Python paralelo (6 workers, `COPY BINARY` em lotes de 50k): 10.000.000 transações, 500.000 contas, ~1,44M eventos de reconciliação em **1m57s** (alvo era ~20 min).
**Desafio:** Três bugs de `COPY BINARY`/geração temporal, todos travando ou corrompendo a carga.
**Solução:** (1) `float` puro em coluna `NUMERIC` → `InvalidBinaryRepresentation`, resolvido com `Decimal`; (2) sem `copy.set_types()`, `CHAR(3)` desalinha o stream binário e o erro aparece em coluna arbitrária adiante — resolvido com `set_types` explícito + `EnumInfo.fetch`/`register_enum`; (3) sortear timestamp uniformemente no mês corrente gerava dado no futuro — resolvido clipando em "agora".
**Por quê:** Divisão do trabalho por faixa de tempo contínua (não por linha) mantém poucos chunks quentes por worker. Divisão aleatória faria os 6 workers escreverem nos 338 chunks ao mesmo tempo.
**Trade-off:** CPF/CNPJ sintéticos sem dígito verificador válido (não é requisito). Amostragem de contas via `ORDER BY id LIMIT` em vez de `TABLESAMPLE SYSTEM`, que retorna 0 linhas em tabela pequena.
**Evidência:** commit `f6dd731`; testes 05.1–05.7; `scripts/ambiente/DOCKER-LOCAL.md`.
**Status:** ok — *Revisado na etapa 7: `load_reconciliation()` tinha dois defeitos de distribuição, corrigidos lá.*

---

## 6. queries-antes-indices

**Entregue:** Q1–Q4 na versão ingênua, `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` capturado em `qN_before.txt` com protocolo de mediana. Medianas: Q1 12.115ms, Q2 8.103ms, Q3 1.285ms, Q4 2.814ms.
**Desafio:** Q4 (self-join) estourava `/dev/shm` com `could not resize shared memory segment` — o default do Docker é 64 MB, e a janela de 7 dias aqui tem ~959k linhas (~5× a referência da especificação).
**Solução:** `shm_size: "1gb"` no serviço timescaledb. Container recriado preservando o volume (10M confirmados intactos).
**Por quê:** Alternativa descartada: registrar o erro como "prova de que o anti-padrão é ruim". Seria conveniente demais — o erro era de configuração de ambiente, não da query; sem medir, não haveria "antes" para comparar.
**Trade-off:** Q1 e Q3 leram 100% de cache (`shared read=0`) por rodarem 4× em sequência. Reportado como está, sem forçar leitura fria artificial.
**Evidência:** commit `80162ac`; `desafio-1/queries/MEDICOES.md`; testes 06.1–06.5.
**Status:** ok — *Revisado na etapa 7: `q2_before.txt` foi remedido após correção do dado.*

---

## 7. indices-e-otimizacao

**Entregue:** `init/timescaledb/03_indexes.sql` (4 índices: 2 parciais, 2 com `INCLUDE`), Q2/Q3/Q4 otimizadas, query de gapfill 48h, `desafio-1/REPORT.md` com tabela antes/depois. Ganhos: Q3 3,3×, Q4 2,2×, Q2 nulo.
**Desafio:** O índice parcial de Q2 pressupõe ~8% de linhas divergentes. O dado real tinha **86%** — o gerador da etapa 05 calculava divergência como percentual do valor (toda TED de R$100k divergia em R$100) e gravava `reconciled_at = now()` em todas as linhas, então "últimos 30 dias" não filtrava nada.
**Solução:** `load_reconciliation()` corrigido (divergência absoluta em centavos aplicada a ~8% das linhas; `reconciled_at` derivado de `created_at`). Só `reconciliation_events` foi recarregado — os 10M de `transactions` intactos. Q2 remedida do zero: índices removidos → novo `before` → índices recriados → novo `after`.
**Por quê:** Alternativa descartada: manter o dado e documentar os 86%. Invalidaria a premissa de seletividade que justifica o índice parcial — a decisão técnica ficaria sem sustentação no relatório.
**Trade-off:** `q2_before.txt` deixou de ser o arquivo original da etapa 06 (documentado). Q4 retorna 0 linhas nas duas versões — o dataset não gera duplicatas por coincidência exata.
**Evidência:** commit `ef44fc8`; `desafio-1/REPORT.md`; testes 07.1–07.6.
**Status:** ok — Q1 fica sem "depois" até a etapa 08 (sua otimização é ler do CAgg).

---

## 7b. Correção do audit.sh (fora da esteira)

**Entregue:** `audit.sh` volta a 0 FAIL de forma estável.
**Desafio:** O script buscava etapas só em `scripts/roadmap/*.md`. Toda vez que uma etapa fechava e era movida para `concluidas/`, ele deixava de encontrá-la e acusava FAIL falso. Acumulou 9 FAILs entre as etapas 02 e 07.
**Solução:** Helper `step_file NN` resolve o caminho nos dois diretórios; `has_impeditivo_ficha` passa a checar só dentro da seção `## IMPEDITIVOS` (evita falso-positivo de prosa em STATUS); a checagem A6.2 ("código de aplicação antes da hora") virou condicional ao repo ainda não achatado.
**Por quê:** Estava normalizando ignorar FAILs "conhecidos" a cada fechamento — o que anula o valor de um teste de regressão.
**Trade-off:** Nenhum. O teste que contava `Estado: BLOQUEADA` foi substituído por um sinal imutável (presença do impeditivo da ficha), porque `Estado:` muda para `CONCLUÍDA` ao fechar.
**Evidência:** commit `9ce06f9`.
**Status:** ok

---

## Premissas assumidas (decisões tomadas sem confirmação)

| # | Premissa | Etapa |
|---|---|---|
| 1 | Serviços `ref-sync` e `api` usam `desafio-2/pipeline/<nome>/` como contexto de build — nenhum S-doc especifica; adotado por analogia ao `cdc-consumer`. | 02 |
| 2 | `accounts` gerado com Zipf pelas mesmas 15 instituições, ~18% CNPJ / 82% CPF, documentos sem dígito verificador válido. Nenhum S-doc detalha o gerador de contas. | 05 |
| 3 | Os 12 meses do dataset terminam no mês corrente (não no anterior), para a janela de `pending` das últimas 48h existir no dado. | 05 |
| 4 | `03_indexes.sql` usa `CREATE INDEX IF NOT EXISTS` — o plano não especificava; sem isso `make indexes` aborta na segunda execução. | 07 |
| 5 | Divergência de reconciliação recalibrada para ~8% via valor absoluto em centavos. O alvo de 8% vem da especificação; a forma de chegar lá foi decisão minha. | 07 |
| 6 | `shm_size: 1gb` no timescaledb (default 64 MB do Docker). | 06 |

## Dívida técnica em aberto

| Item | Impacto | Origem |
|---|---|---|
| `archive_command=pgbackrest ...` gera `FATAL: archive command failed (exit 127)` no log continuamente — `pgbackrest` não está instalado na imagem. | Ruído no log. Não afeta escrita/leitura. Resolve na etapa 15. | 04 |
| `prometheus` reinicia em loop se subir sozinho — falta `./init/prometheus`. | Perfil `full` incompleto. Resolve na etapa 15. | 02 |
| `--profile core up -d` completo nunca foi validado (seed/api sem Dockerfile). | Critério de aceite da etapa 02 parcial. | 02 |
| Q4 retorna 0 linhas em ambas as versões — dataset não produz duplicatas reais. | Mede custo de procurar, não de retornar. Declarado no REPORT. | 07 |
| RAM do Docker: 8,3 GB (a especificação assume 32 GB; perfil `full` declara ~20 GB de teto). | Risco de OOM quando o perfil `full` subir inteiro. | ficha de ambiente |
| `make` ausente no PATH — 3 testes ficam SKIP. | Validação depende de container auxiliar nesta máquina. | 03 |

## Pontos fortes para a apresentação

- **O índice que não melhorou está no relatório com a explicação.** Q2: ambos os índices são usados (`Parallel Index Scan` no parcial, `Index Only Scan` no covering — o `INCLUDE` eliminou o heap fetch), e ainda assim o ganho foi nulo, porque o gargalo é o `Seq Scan` no lado de `transactions` do join. Acelerar o lado pequeno de um join não muda o custo do lado grande.
- **Um bug de dado foi encontrado *pela* medição.** A tentativa de justificar o índice parcial expôs que 86% das reconciliações divergiam (o gerador usava percentual do valor). Sem medir, o índice teria sido entregue com uma premissa falsa por baixo.
- **O protocolo de medição é o que dá crédito aos números:** 4 execuções, descarta a primeira (aquece cache), mediana das 3, sempre reportando `shared hit` vs `read`. Q1 e Q3 deram `read=0` — reportado como está, sem inventar leitura fria.
- **Seed de 10M em 1m57s** dividindo por faixa de tempo contínua, não por linha: cada worker mantém poucos chunks quentes. Divisão aleatória faria 6 workers escreverem nos 338 chunks simultaneamente.
- **A suíte de regressão pegou a própria regressão do plano.** Ao criar índices na etapa 07, os testes 04.6 e 06.3 falharam — eles asseriam "nenhum índice". Foram reescritos para asserir a evidência (`ausência de Index Scan nos qN_before.txt`) em vez de estado global, com o desvio registrado.

## Perguntas prováveis do avaliador + resposta curta

**Por que o índice parcial de Q2 não melhorou nada?**
Porque ele acelera o lado errado. `reconciliation_events` tem 115k linhas divergentes; `transactions` tem 10M e continua em `Seq Scan` na janela de 30 dias. O próximo passo não é outro índice, é reduzir o lado grande do join.

**Você mediu com cache quente ou frio?**
Quente, e declarado. Protocolo: descarta a primeira execução, mediana das 3 seguintes, com `shared hit` vs `read` visível em cada `EXPLAIN`. Comparar uma query fria com uma quente produziria ganho fictício.

**Q4 não retorna nada. A otimização vale?**
O ganho medido é 2,2× (2.814ms → 1.274ms) no custo de *procurar*. O self-join constrói combinações e descarta (`Rows Removed by Join Filter: 319.645`) — cresce quadraticamente. A window function faz uma passada — cresce linearmente. Em 7 dias a diferença é 2,2×; em 90 dias o self-join fica inviável.

**Por que `status` fica fora do `ORDER BY` do ClickHouse?**
[NÃO REGISTRADO] — decisão está na especificação (S04), mas a etapa 11 ainda não foi executada nesta sessão.

**Por que não usou Airflow?**
[NÃO REGISTRADO] — decisão consta como travada no orquestrador do projeto (`D06-Por-que-nao-Airflow.md`), mas o documento não foi lido nesta sessão.

**Como garante que o seed não roda duas vezes?**
`seed_control` com `CHECK (id = 1)` e `finished_at`. Se estiver preenchido, o gerador avisa e sai. `--force` limpa antes. Testado: segunda execução não alterou a contagem.

**O ambiente sobe inteiro com um comando?**
Ainda não — 5 serviços são build local e 4 deles só ganham Dockerfile nas etapas 13–15. Hoje sobem os 4 com imagem pronta mais o `seed`.

---
---

# Continuação — etapas 08 a 13 e replanejamento E0–E4

*Acrescentado em 2026-08-04. Blocos acima preservados como estavam.*

---

## 8. caggs-compressao-retencao

**Entregue:** 2 continuous aggregates (`cagg_volume_hourly`, `cagg_settlement_latency_daily`), política de compressão, política de retenção criada e desabilitada, `retention-demo.sh`.
**Desafio:** `percentile_agg` não existe na imagem fixada — o `timescaledb_toolkit` não vem instalado.
**Solução:** Plano B previsto na especificação: `percentile_cont` em view. Confirmado com o usuário antes de aplicar.
**Por quê:** Alternativa descartada: trocar a imagem por uma com toolkit. Reprodutibilidade é requisito e as versões estão fixadas de propósito.
**Trade-off:** `failed_count`/`total_count` do segundo CAgg ficaram estruturalmente inúteis; schema mantido com aviso no DDL. Q2/Q3/Q4 `after` não foram remedidas sobre dado comprimido — seria outro experimento.
**Evidência:** commit `a397bf4`; 4 desvios registrados em `99-validacao-final.md`.
**Status:** ok

---

## 9. lgpd-sanitizacao

**Entregue:** `lgpd-sanitization.md` (276 linhas), `05_lgpd_erasure.sql`, procedimento de apagamento testado.
**Desafio:** O passo do ClickHouse não podia ser executado — as etapas 11 e 13 ainda não existiam.
**Solução:** Documentado como procedimento futuro, declarado como não-executado.
**Por quê:** Escrever o procedimento sem poder rodá-lo é honesto se declarado; apresentá-lo como testado não seria.
**Trade-off:** Metade do procedimento (lado ClickHouse) fica sem evidência de execução.
**Evidência:** commit `7907fb5`. Nenhum desvio registrado.
**Status:** parcial — lado TimescaleDB testado, lado ClickHouse documentado.

---

## 10. legado-e-migracao-aurora

**Entregue:** Schema do legado (50k users, 80k accounts, 480 configs), bloat induzido (`n_dead_tup=400.000`), 2 queries com EXPLAIN antes/depois, `migration-analysis.md`.
**Desafio:** Legacy Q1 não ganhou tempo após `ANALYZE` — o ganho real foi na estimativa de linhas, não no relógio.
**Solução:** Reportado como está, sem procurar outro número que parecesse melhor.
**Por quê:** O mesmo princípio do índice que não melhorou na etapa 07: medição que não confirma a hipótese entra no relatório do mesmo jeito.
**Trade-off:** `institution_configs` ficou com 480 linhas contra ~450 da especificação — ordem de grandeza igual, número exato não é contrato.
**Evidência:** commit `4e709bb`; 2 desvios em `99-validacao-final.md`.
**Status:** ok — `migration-analysis.md` tem 60 linhas para um requisito de "1 página com 4 sub-tópicos"; a auditoria posterior classificou como magro.

---

## 11. schema-clickhouse

**Entregue:** `transactions_raw` (ReplacingMergeTree), 2 MVs com `AggregatingMergeTree`, `dict_institutions` resolvendo dado real do legado.
**Desafio:** O DDL literal da especificação não compilava — 4 colunas de estado agregado declaradas como `Float32` puro, mas as MVs produzem `Nullable(Float32)`.
**Solução:** Redeclaradas como `AggregateFunction(_, Nullable(Float32))`.
**Por quê:** Alternativa descartada: forçar `assumeNotNull` na MV. Mascararia a origem do `NULL` em vez de tipar corretamente.
**Trade-off:** Divergência do S-doc, registrada. `clickhouse` teve de subir por nome de serviço — `--profile core` estava quebrado por bug pré-existente do compose (corrigido depois no E0).
**Evidência:** commit `110418f`; 2 desvios em `99-validacao-final.md`.
**Status:** ok

---

## 12. backfill-e-query-subsegundo

**Entregue:** `backfill-clickhouse.sh` (10M PG→ClickHouse), query Pix 24h vs D-1 com **mediana de 8ms** contra alvo de 1000ms.
**Desafio:** A MV já estava ativa durante o backfill e duplicava as linhas — achado real do ambiente, não previsto no plano.
**Solução:** Backfill ajustado para não colidir com a MV incremental.
**Por quê:** A query ilustrativa da especificação também não compilava contra o schema real (`countIfMerge` vs `status` no `GROUP BY`) — reescrita.
**Trade-off:** Teste `11.6` foi invalidado por avanço legítimo de escopo, registrado.
**Evidência:** commit `db21396`; `desafio-1/REPORT.md`; 3 desvios em `99-validacao-final.md`.
**Status:** ok

---

## 13. pipeline-cdc — investigado e **descartado**

**Entregue:** Consumidor CDC completo e testado (`main/transform/sink/metrics/config`), `demo-mutation.sh`, `ETAPA13-ESTADO-PAUSADO.md`. O conector Debezium **não entra na entrega final**.
**Desafio:** O CDC parou de avançar o `confirmed_flush_lsn`. Conector `RUNNING`, sem exceção, CPU baixa. Reproduzido 2× de forma idêntica. Quatro hipóteses levantadas na hora — todas erradas.
**Solução:** A auditoria seguinte isolou a decodificação lógica **sem o Debezium no circuito** e provou a causa: `publish_via_partition_root` não funciona sobre hypertable. Hypertable não é tabela particionada nativa (`relkind='r'`, chunk com `relispartition='f'`), então o parâmetro não tem relação pai/filho sobre a qual agir.
**Por quê:** O gatilho "2h sem CDC → parar e aguardar decisão" funcionou e produziu o documento de estado pausado. O que faltou foi, ao parar, **reabrir a premissa** em vez de só listar hipóteses de execução.
**Trade-off:** Tempo gasto perseguindo o CDC não foi para requisitos do Desafio 3, que estavam em zero. Debezium nunca foi requisito do PDF — micro-batch por watermark é opção de primeira classe no § 4.2 A.1.
**Evidência:** commit `328e8a9`; `AUDITORIA-E-REPLANEJAMENTO.md`.

Prova experimental, com o Debezium fora do circuito:

```
pg_logical_slot_peek_binary_changes        -> 0 mudanças
ALTER PUBLICATION ... ADD TABLE <o chunk>  -> 6 mudanças imediatamente
```

**Status:** parcial — descartado por decisão, com causa-raiz provada. Código preservado no profile `cdc-experimento` como artefato da decisão.

---

## 13b. Auditoria e replanejamento (fora da esteira)

**Entregue:** `AUDITORIA-E-REPLANEJAMENTO.md` (453 linhas) — diagnóstico contra o ambiente vivo, matriz de rastreabilidade contra o PDF, roadmap E0–E7.
**Desafio:** Três achados que mudaram o plano: a premissa do `pubviaroot` era factualmente falsa; faltavam ~40% dos requisitos do PDF (quase todos no Desafio 3); `run_all.sh` reportava 81 pass/0 fail mas a realidade era 77 pass/**4 fail**.
**Solução:** Abandonar o Debezium e adotar o plano B já previsto, reaproveitando ~80% do código escrito. Redirecionar o tempo restante para o Desafio 3.
**Por quê:** Causa estrutural identificada: *uma premissa não verificada foi promovida a contrato de arquitetura*. O RegexRouter, rotulado "rede de segurança", era na verdade o único mecanismo que funcionava — e mascarou a falha do caminho principal. O projeto já tinha sido mordido 3× pelo mesmo padrão (toolkit ausente na 08, tag de imagem inexistente na 13, `pubviaroot`).
**Trade-off:** Nenhum código foi commitado nesta rodada — só diagnóstico.
**Evidência:** `AUDITORIA-E-REPLANEJAMENTO.md` § 2.3 (prova experimental) e § 2.4 (causa de processo).
**Status:** ok

---

## E0/E1. Estabilização do ambiente e verificação de premissas

**Entregue:** Todos os P0 da auditoria resolvidos; 6 premissas testadas antes de escrever código.
**Desafio:** O slot de replicação parado retinha **17,7 GB de WAL e crescia**. `archive_command` apontava para pgBackRest ausente da imagem (exit 127 por segmento) — e o Postgres não recicla WAL não-arquivado.
**Solução:** Slot/conector/publication removidos; `archive_mode=off` até o E4 trazer o binário real. `pg_wal` 17,7 GB → 1,0 GB; volume 20,8 GB → 4,1 GB. Backup dos 3 volumes com drill de restauração executado (RTO 7s).
**Por quê:** Arquivamento quebrado é pior que desligado: dá ilusão de PITR e ainda enche o disco.
**Trade-off:** Ficou sem arquivamento de WAL do E0 ao E4, deliberadamente.
**Evidência:** commit `4051e42`; `PREMISSAS-VERIFICADAS.md`. Suíte: 77/4/3 → **93 pass, 0 fail, 3 skip**.
**Status:** ok — **3 de 6 premissas refutadas** (índice em `updated_at` inexistente; pgbackrest e clickhouse-backup ausentes das imagens).

---

## E2. sync-worker — pipeline TimescaleDB → ClickHouse

**Entregue:** Micro-batch por watermark de `updated_at` substituindo o CDC. Propagação medida em ~4s contra alvo de freshness <30s.
**Desafio:** A janela incremental fazia `Seq Scan` de 10M + `Sort` — **85.587 buffers para devolver 1 linha**. Criar o índice em `updated_at` não bastou: a hypertable é particionada por `created_at`, então filtrar só por `updated_at` não exclui chunk nenhum (`Chunks excluded during startup: 0`).
**Solução:** Predicado duplo na query do worker (`updated_at >= marca` **e** `created_at >= marca - 7d`): 85.587 → **17 buffers** (~5.000×), e o `Merge Append` sobre índices ordenados dispensa o `Sort`.
**Por quê:** Medido no E1, não suposto. O índice sozinho é a solução intuitiva e estava errada.
**Trade-off:** Perde `DELETE` (limitação conhecida do watermark, declarada). Janela de 7 dias no predicado é um limite prático assumido.
**Evidência:** commit `bb29020`. Resiliência validada: ClickHouse derrubado no meio do ciclo — worker sobreviveu em retry, watermark não avançou, linha recuperada sozinha. Suíte: **104 pass, 0 fail, 3 skip**.
**Status:** ok

---

## E4. Backup e recovery dos 3 bancos

**Entregue:** pgBackRest → MinIO via S3/HTTPS para os 2 Postgres (full + incremental + WAL contínuo, com PITR); `BACKUP` nativo para o ClickHouse; `restore-drill.sh` com as 3 contagens do PDF § 5.2 A.2.
**Desafio:** Três bugs só apareceram executando o drill: a instância restaurada recusa concluir o recovery se `max_connections`/`max_wal_senders`/`max_replication_slots` forem menores que os do primário; precisa de `archive_mode=off`, senão escreve a linha de tempo de um clone efêmero no repositório real e corrompe o histórico de produção; sem um incremental antes do exercício, o restore traz linhas de execuções anteriores do próprio drill.
**Solução:** pgBackRest roda **dentro** do container do banco via imagem derivada — instalar por `docker exec` sobreviveria até o primeiro `compose down`. Restore vai para instância paralela na 5499, nunca sobre o principal.
**Por quê:** `clickhouse-backup` não existe na imagem (refutado no E1) e o motor nativo só precisava do disco declarado — instalar binário de terceiro para um recurso que o servidor já tem seria dívida sem contrapartida. MinIO em HTTPS não foi preferência: `repo1-type=s3` sempre fala TLS.
**Trade-off:** Certificado auto-assinado no ambiente local. Restaurar por cima do dataset de produção para provar que o backup funciona é o tipo de teste que vira o próprio incidente — por isso instância paralela.
**Evidência:** commit `f8a0e2e`. Medidos: TimescaleDB full 3,1 GB → 1,1 GB (zstd-3) em 29,6s; **RTO 22-23s, RPO 60s**. Suíte: **118 pass, 0 fail, 3 skip**.
**Status:** ok — as 5 linhas do drill foram criadas *depois* do último full, então só voltaram pelo replay do WAL. É a diferença entre "o backup existe" e RPO.

---

## E4b. Chave privada do MinIO fora do versionamento

**Entregue:** `private.key` no `.gitignore`, `gen-certs.sh` para regenerar após clone.
**Desafio:** O commit do E4 versionou a chave privada do certificado auto-assinado.
**Solução:** Removida do versionamento; `public.crt` continua versionado — é o CA que o pgBackRest usa para validar o MinIO, e sem ele os bancos não sobem.
**Por quê:** Certificado só vale no ambiente local, mas chave privada não se versiona.
**Trade-off:** Nenhum. Quem clonar precisa rodar `gen-certs.sh`.
**Evidência:** commit `17a90dc`.
**Status:** ok — a chave permanece no histórico do git (não houve rewrite). Sem impacto real: é auto-assinada e local, regenerável.

---

## Premissas assumidas — continuação (etapas 08–E4)

| # | Premissa | Etapa |
|---|---|---|
| 7 | `percentile_cont` em view no lugar de `percentile_agg` (toolkit ausente). Confirmado com o usuário. | 08 |
| 8 | Procedimento LGPD testado sobre conta sintética descartável, não conta real. Confirmado com o usuário. | 09 |
| 9 | `institution_configs` com 480 linhas (15 × 4 × 8) em vez de ~450 da especificação. | 10 |
| 10 | 4 colunas de estado agregado do ClickHouse como `Nullable(Float32)` — o DDL literal não compilava. | 11 |
| 11 | `backfill-clickhouse.sh` na raiz de `scripts/`, não em `desafio-1/scripts/`. | 12 |
| 12 | Janela de `created_at` de 7 dias no predicado duplo do sync-worker. | E2 |
| 13 | ClickHouse usa `BACKUP` nativo em vez de `clickhouse-backup` (ausente da imagem). | E4 |
| 14 | Serviços sem Dockerfile movidos para o profile `pendente`; CDC preservado em `cdc-experimento`. | E0 |

## Dívida técnica — continuação

| Item | Impacto | Origem |
|---|---|---|
| `migration-analysis.md` tem 60 linhas para um requisito de "1 página com 4 sub-tópicos". | Requisito atendido de forma magra. | 10 / auditoria |
| Lado ClickHouse do procedimento LGPD documentado, não executado. | Metade do procedimento sem evidência. | 09 |
| sync-worker não propaga `DELETE` (limitação do watermark). | Declarada. Herdada do plano B da especificação. | E2 |
| Chave privada do MinIO permanece no histórico do git. | Baixo — auto-assinada, local, regenerável. | E4b |
| API que serve o ClickHouse (Desafio 1 C.5), ref-sync, ADR, diagramas, runbook, dashboards, alertas, incidente SEV-1. | **Requisitos do PDF ainda não entregues.** | auditoria § 2.1 |
| `git` da raiz (`Desafio técnico/Trio/`) com 0 commits; diretório fantasma `trio-data-challenge;C`. | Confusão sobre onde está o repositório de entrega. | auditoria R11 |

## Pontos fortes — continuação

- **A causa-raiz do CDC foi provada, não deduzida.** Isolar a decodificação lógica sem o Debezium no circuito (`peek_binary_changes` → 0 mudanças; `ADD TABLE <chunk>` → 6 mudanças) transforma "não sei por que travou" em "hypertable não é tabela particionada nativa, então `pubviaroot` não tem sobre o que agir".
- **O fallback silencioso foi o verdadeiro defeito.** O RegexRouter, documentado como "rede de segurança", era o único caminho funcionando — e ao ser removido "para melhorar performance", derrubou tudo. Lição registrada: mecanismo de fallback tem de contar que agiu.
- **3 de 6 premissas foram refutadas ao serem testadas** antes de virar código (E1). A mais cara: criar índice em `updated_at` é a solução intuitiva e **não resolve** — sem predicado em `created_at`, a hypertable não exclui chunk nenhum. 85.587 → 17 buffers.
- **O drill de recovery restaura para instância paralela, nunca sobre o principal.** E as linhas verificadas foram criadas *depois* do último full — só voltaram por replay de WAL. Prova RPO, não só "o backup existe".
- **Arquivamento quebrado é pior que desligado.** `archive_command` apontando para binário ausente reteve 17,7 GB de WAL e dava ilusão de PITR. Ficou `off` de propósito até o binário existir de verdade.

## Perguntas prováveis — continuação

**Por que abandonou o Debezium?**
Porque `publish_via_partition_root` não funciona sobre hypertable — provado isolando a decodificação lógica sem o Debezium no circuito. Não é bug do Debezium; é a ferramenta errada para esta tabela. Micro-batch por watermark é opção de primeira classe no PDF § 4.2 A.1; Debezium nunca foi requisito.

**Como o sync-worker garante que não perde dado se o destino cair?**
O watermark só avança **depois** da escrita confirmada. Testado derrubando o ClickHouse no meio do ciclo: worker ficou em retry exponencial, watermark não avançou, e a linha inserida durante a queda foi recuperada sozinha quando o destino voltou.

**Qual o RTO e o RPO medidos?**
RTO 22–23s no drill; RPO 60s, limitado pelo `archive_timeout`. Ambos medidos executando o exercício, não estimados.

**Por que `status` fica fora do `ORDER BY` do ClickHouse?**
[NÃO REGISTRADO] — a etapa 11 foi executada fora desta sessão; não tenho o raciocínio de primeira mão.

**Por que não usou Airflow?**
[NÃO REGISTRADO] — consta como decisão travada apontando para `D06-Por-que-nao-Airflow.md` no vault, nunca lido nesta sessão.

**Qual a duração da apresentação?**
[NÃO REGISTRADO] — o roadmap afirma "30 a 45 min (PDF § 2.1 e § 7)", mas o PDF não foi lido nesta sessão para confirmar o texto literal.

---

## R. Reconciliação da esteira (fora da esteira)

**Entregue:** Roadmap e repositório voltam a estar sincronizados; o fluxo padrão do `CLAUDE.md` (ler a próxima etapa em `scripts/roadmap/`, executar, fechar) volta a valer.
**Desafio:** Depois da auditoria, quatro entregas (E0/E1/E2/E4) rodaram fora da esteira — sem arquivo de etapa, sem `ESTADO HERDADO`, sem passar por `concluidas/`. O `CLAUDE.md` § 1 apontava para a etapa 13, já descartada, como "próxima". A etapa 15 mandava refazer backup que o E4 já tinha entregue.
**Solução:** 13 fechada como DESCARTADA com a causa provada; criada a **13.5** nascendo CONCLUÍDA, que registra E0/E1/E2/E4 retroativamente; **15** reescrita sem backup (só observabilidade, runbook e incidente); criada a **16** para as lacunas PARCIAIS do PDF que nenhuma etapa cobria. `audit.sh` ajustado para 18 etapas e com o rastreio do § 5.2 A.1/A.2 apontando para a 13.5.
**Por quê:** Alternativa descartada: adotar a nomenclatura E0–E7 e abandonar a numeração. Manteria o `audit.sh` e o rastreio do PDF desalinhados, e o `audit.sh` é o que impede requisito de sumir sem ninguém notar.
**Trade-off:** A esteira ficou com uma numeração fracionária (`13.5`), que é feia mas honesta — preserva a ordem cronológica real sem renumerar etapas já fechadas e commitadas.
**Evidência:** `scripts/roadmap/concluidas/13.5-sync-worker-e-backup.md`; `99-validacao-final.md` § Desvios (4 linhas novas). `audit.sh` 83 pass / 0 fail; `run_all.sh` 118 pass / 0 fail.
**Status:** ok

---

## Estado da entrega em 2026-08-04

Próxima etapa pelo fluxo padrão: **14 — ref-sync, API e ADR**.

| Etapa | Entrega | Requisitos do PDF que fecha |
|---|---|---|
| 14 | ref-sync, API FastAPI, diagramas, ADR | 1 C5 · 2 B1, B2, C1, C2 |
| 15 | 4 dashboards, 6 alertas, runbook, incidente SEV-1 | 3 A3, B1, B2, C |
| 16 | P95/P99, retenção, Aurora expandido, funil, Dictionary vs JOIN, LGPD no CH | 1 A4b, A5, B3, C2b, C3 |
| 99 | Sequência do zero, README, REPORT, roteiro | § 6.1 (os 7 critérios) |

Backup e recovery (§ 5.2 A.1 e A.2) foram entregues na 13.5 — não estão pendentes.
