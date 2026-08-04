# Memorial Técnico — Trio Data Challenge

**Projeto:** Desafio Técnico — Engenheiro de Dados Sênior, Trio Grupo Financeiro
**Stack:** TimescaleDB (pg16), PostgreSQL 16, ClickHouse 24.8, Redpanda v24.2.7, Debezium 2.7, Grafana 11.3.0, Prometheus v2.54.1, MinIO, Python 3.12 (psycopg 3.2.3, numpy 2.1.3), Docker Compose
**Objetivo:** Montar ambiente local com 3 bancos, carregar 10M de transações sintéticas, medir e otimizar queries com evidência de `EXPLAIN` antes/depois, e montar pipeline CDC TimescaleDB → ClickHouse.
**Gerado em:** 2026-08-03 (etapas 01–07 concluídas; 08–15 e 99 pendentes)

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
