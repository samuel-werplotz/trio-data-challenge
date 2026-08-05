# LOG DE EXECUÇÃO

Scratchpad descartável, não histórico permanente. Mínimo, sem prosa. Campo que não se aplica é omitido. Nunca repetir o que já está no commit ou no `.md` da etapa concluída.

Formato do bloco, um por etapa:

```
## NN · AAAA-MM-DD
Quebrou: <o que falhou, ou omitir>
Decidido: <o que foi decidido, ou omitir>
```

---

## 01 · 2026-08-03

## 02 · 2026-08-03
Decidido: paths de build local sem S-doc (ref-sync, api) seguem convenção do cdc-consumer (S05: `desafio-2/pipeline/<serviço>/`). Validação de `up --profile core` restrita aos 4 serviços com imagem pronta — seed/api (build) ficam para 05/14.

## 03 · 2026-08-03
Quebrou: `winget install GnuWin32.Make` falhou por erro de rede (Sourceforge). Sem `make` no PATH deste Windows.
Decidido: validar `make help`/`make -n up`/`make seed`/`make check` via container Docker auxiliar (`docker:27-cli` + socket montado + `COMPOSE_PROJECT_NAME` explícito), já que Docker está de pé. `run_all.sh` faz SKIP nos 3 testes que dependem de `make` neste ambiente específico.

## 04 · 2026-08-03
Quebrou: primeira versão de `02_seed_marker.sql` usou colunas inventadas em vez das literais de S02 — pego ao ler a ORIGEM da etapa 05, corrigido antes do commit.
Decidido: volume do timescaledb recriado 2x (schema inicial + correção do seed_control) — sem perda de dado real, nenhum seed havia rodado.

## 05 · 2026-08-04
Quebrou: `COPY BINARY` com `float`/sem `set_types` corrompia o stream binário (NUMERIC e CHAR(3)); timestamps do mês corrente geravam dado no futuro. Todos corrigidos antes do seed real rodar.
Decidido: seed real de 10M rodou em 1m57s (vs ~20min estimado em S02) — 6 workers, COPY BINARY em lotes de 50k. 12 meses do dataset terminam no mês corrente para a janela de pending/48h cair dentro do range.

## 06 · 2026-08-04
Quebrou: Q4 (self-join) estourava `/dev/shm` (64MB default) — nosso volume em 7 dias é ~5x a referência de S06.
Decidido: `shm_size: 1gb` no serviço timescaledb (docker-compose.yml). Medianas registradas: Q1 12.115ms, Q2 8.103ms, Q3 1.285ms, Q4 2.814ms (self-join mais rápido que o esperado — planejador usou Parallel Hash Join).

## 07 · 2026-08-04
Quebrou: gerador de `reconciliation_events` (etapa 05) fazia 86% das linhas divergirem (divergência percentual do valor) e gravava `reconciled_at = now()` em todas — as duas coisas invalidavam a premissa do índice parcial de Q2 e o filtro de 30 dias. Corrigido e só essa tabela recarregada; Q2 remedida do zero (before + after).
Decidido: Q2 entra no REPORT como "índice que não melhorou" — ambos os índices são usados, mas o gargalo é o Seq Scan no lado de `transactions` do join. Testes 04.6/06.3 reescritos (asseriam "sem índice", que esta etapa invalida por design).

## 08 · 2026-08-04
Quebrou: `timescaledb_toolkit` não existe na imagem fixada `latest-pg16` — `percentile_agg`, que S03 usa no CAgg 2, é inalcançável sem trocar a imagem (proibido pela Seção 2). Adotado o plano B que o próprio S03 prevê, com confirmação do usuário.
Quebrou: `failed_count` do CAgg 2 é estruturalmente 0 — o `WHERE settled_at IS NOT NULL` de S03 exclui toda transação `failed`. Schema mantido (é contrato), mas a coluna ganhou aviso no DDL e a Q3 via CAgg não calcula taxa de falha.
Decidido: compressão deu **5,0× no total** mas **23,5× só na tabela** — os 4 índices da etapa 07 pesam 1.484 MB contra 1.188 MB de dado, e é isso que puxa a taxa para baixo dos 10–20× que S03 esperava. O número virou seção do REPORT em vez de nota de rodapé: as duas otimizações do desafio se pagam uma contra a outra.
Decidido: Q1 12.115ms → 23ms (**521×**, buffers 95.670 → 500); Q3 via CAgg 1.285ms → 3,4ms (383×). Equivalência do CAgg com o raw verificada linha a linha — 0 divergências, mas só com o corte alinhado a `date_trunc('hour')`; no meio do bucket o mês da borda diverge em ~193 linhas.

## 09 · 2026-08-04
Decidido: `pgcrypto` não vinha instalado (só `digest()` do procedimento de S09 precisa dele) — `CREATE EXTENSION IF NOT EXISTS pgcrypto` resolvido no próprio `05_lgpd_erasure.sql`, sem o tipo de conflito do toolkit da etapa 08 (extensão disponível na imagem, só não habilitada).
Decidido: teste do procedimento `anonimizar_conta` rodado sobre conta **sintética** (`desafio-1/scripts/lgpd-erasure-demo.sh`), não sobre uma das 500k contas reais — mesmo padrão do `retention-demo.sh` da etapa 08. Confirmado com o usuário antes de escrever, dado que o UPDATE de anonimização é irreversível sobre dado real.
Decidido: Passo 2 (propagação ao ClickHouse) documentado como procedimento futuro, não executável — ClickHouse (etapa 11) e CDC (etapa 13) ainda não existem neste ambiente. Checklist de S09 mantém os 5 itens, mas o doc marca quais são verificáveis hoje.

## 10 · 2026-08-04
Quebrou: ao medir o bloat pela primeira vez rodei `ANALYZE` manual por engano antes de capturar o "antes" — contaminava o cenário de estatística desatualizada que S07 pede. Resolvido truncando e recarregando o legado do zero (`RESTART IDENTITY CASCADE`), com `autovacuum_enabled=false` em `legacy_accounts`/`institution_configs` para o "antes" não ser corrigido sozinho pelo autovacuum antes da medição.
Quebrou: seed original de `legacy_accounts`/`legacy_configs` assumia ids sequenciais a partir de 1 (`1 + g % 15`); `SERIAL` não é transacional, então uma segunda tentativa após rollback deixava buracos e a FK falhava. Corrigido para montar `array_agg(id ORDER BY id)` uma vez e indexar, em vez de assumir contiguidade.
Quebrou: teste `06.2` do `run_all.sh` (esperava 4 arquivos `Buffers:` em `*_before.txt`) quebrou com os `legacy_qN_before.txt` novos no mesmo diretório. Glob restrito a `q[1-4]_before.txt`.
Decidido: bloat medido em 83,3% de linhas mortas, `legacy_accounts` ocupando 70 MB para 80.000 linhas úteis (~6×) — dentro do previsto por S07. Legacy Q1 não mudou de tempo após ANALYZE (o planner já escolhia Hash Join mesmo com estimativa errada); o ganho real foi na precisão da estimativa (509.298→80.000 linhas). Reportado como está, sem forçar a narrativa do Nested Loop que S07 previu mas não se manifestou nesta escala.

## 11 · 2026-08-04
Quebrou: `docker compose --profile core up` falha — `grafana` (profiles core+full) depende de `prometheus` (só profiles full), erro de config pré-existente não coberto pelos testes 02.1/02.2 (usam --profile full). Contornado subindo `clickhouse` por nome de serviço, sem editar o compose.
Quebrou: DDL literal de S04 para `daily_by_institution`/`status_funnel` declarava `AggregateFunction(avg, Float32)` etc., mas `settlement_seconds` é `Nullable(Float32)` — `avgState`/`quantileState` sobre coluna nullable produzem estado `Nullable`, e a MV falhava com `CANNOT_CONVERT_TYPE` ao inserir. 4 colunas redeclaradas como `AggregateFunction(_, Nullable(Float32))`.
Quebrou: teste `11.2` (status fora do ORDER BY) inicialmente "passava" por acidente — a extração via `grep -oE` cortava a cláusula no primeiro `)` interno (de `toStartOfHour(created_at)`), sobrando string vazia, que trivialmente não contém "status". Corrigido convertendo os `\n` literais da saída do `clickhouse-client` em quebra de linha real antes de isolar a linha do `ORDER BY`.
Decidido: `transactions_raw` (ReplacingMergeTree), 2 tabelas AggregatingMergeTree + 2 MVs, `dict_institutions` — todos criados, `status` fora do ORDER BY confirmado, nenhuma MV com POPULATE, `transactions_raw` vazia (0 linhas), Dictionary resolve `dictGetOrDefault('...','name',tuple('001'),'?')` = "Instituição Parceira 1" (dado real do legado, não fallback).

## 12 · 2026-08-04
Quebrou: `INSERT SELECT` de backfill das 2 MVs duplicou tudo (20M agregados) — as MVs já estavam ativas (etapa 11) e capturaram sozinhas cada bloco mensal do backfill do raw; o `INSERT SELECT` manual depois duplicou o que a MV já tinha inserido em tempo real. Corrigido truncando as tabelas de agregação (raw preservado) e rodando o INSERT SELECT uma única vez.
Quebrou: query ilustrativa de S04 (`countIfMerge(cnt)`) não roda contra o schema real — `status_funnel.status` é coluna do GROUP BY, não filtro pré-embutido em `cnt` (`countState()` puro). Reescrita para derivar "sucesso" via `sumIf(status='settled')` na leitura.
Quebrou: teste `11.6` (esperava `transactions_raw` vazia) invalidado por avanço legítimo — a 12 popula a tabela por design. Reescrito para checar só que a tabela responde a `count()`.
Decidido: backfill dos 12 blocos mensais em 56s, `count(*)` e `count() FINAL` idênticos (10M, sem duplicata), contagem por mês CH vs PG bate exatamente. Query Pix 24h vs D-1 mediu mediana de 7-8ms (alvo <1000ms), `read_rows`=5.882 (lê da MV agregada, não da raw).

## audit.sh · 2026-08-04
Quebrou: `audit.sh` só buscava etapas em `scripts/roadmap/*.md` — depois que uma etapa fecha e move para `concluidas/`, o script deixa de achá-la e reporta FAIL falso (arquivo ausente, esteira com número errado de etapas BLOQUEADA, decisões/PDF não rastreados). Regressão silenciosa a cada fechamento de etapa desde a 02.
Decidido: `step_file NN` resolve o caminho da etapa em `$ROADMAP` ou `$ROADMAP/concluidas`; `has_impeditivo_ficha` checa só dentro da seção `## IMPEDITIVOS` (não em prosa livre de STATUS) para não pegar falso-positivo. A6.2 (código de aplicação "antes da hora") virou condicional a `-d trio-data-challenge` — só faz sentido antes da etapa 01. `audit.sh` volta a 0 FAIL de forma estável, não é mais preciso ignorar FAILs "conhecidos" a cada fechamento.

## 14 · 2026-08-04
Quebrou: `sum(countMerge(cnt))` no endpoint de saúde é `ILLEGAL_AGGREGATION` (agregação dentro de agregação). Reescrito com merge na subconsulta e soma na externa; conferido contra a raw — P95 55.604s vs 57.407s, avg 6.215 vs 6.215.
Quebrou: `HTTPException` de "instituição sem dados" era engolida pelo `except Exception` genérico e virava 503. Instituição inexistente voltou a responder 404 — para um roteador automatizado, "não sei" e "saudável com zero tráfego" são decisões opostas.
Quebrou: Mermaid não aceita linha só com `%%` (sem texto depois) — erro reportado como "Parse error on line 1", que aponta para o lugar errado. Achado por bisecção linha a linha.
Quebrou: testes `14.3`/`14.15` instáveis (1 falha a cada ~4 execuções). Causa real em duas camadas: comparavam dois **acertos** de cache, ambos na casa de 0,006–0,010 ms, onde o jitter decide o vencedor; e a API rodava com 2 workers uvicorn, cada um com seu cache em memória, então a 2ª chamada podia cair no worker sem a entrada. Corrigido nas duas pontas — comparação miss×hit com chave inédita por execução, e API para 1 worker.
Decidido: API com **1 worker** por desenho, não por conveniência de teste — cache em memória por processo significa que cada worker extra é mais um cache, e a mesma chave seria buscada uma vez por worker. Escalar é réplica no orquestrador.
Decidido: `/fraud/duplicates` devolve 0 linhas, e isso é propriedade do dataset (mesma limitação da Q4 no REPORT). A lógica foi provada à parte sobre dado sintético — par a 2 min detectado, par a 8h ignorado — para separar "não achou porque não existe" de "não achou porque está errada".
Decidido: só `dict_institutions` é sincronizado. `dict_institution_config` aparece em `Container-Ref-Sync.md` mas não existe no schema de S04, e criá-lo seria mudança de schema (Seção 5). Worker parametrizado por env, então incluí-lo depois é configuração.
Decidido: detecção por `(count(*), max(updated_at))`, não só pelo máximo — `DELETE` não move o máximo.
Decidido: teste `02.2` atualizado de 8/11 para 10/13 serviços. Os números antigos descreviam `api`/`ref-sync` como esqueleto no profile `pendente`; esta etapa os implementou.
Notado (não é desta etapa): `E2.4` falha de forma intermitente com banco ocioso — o `sync-worker` só registra sucesso quando há linha nova, e o intervalo passa de 300s sozinho. Sem defeito no worker, mas o alerta da etapa 15 não pode ser construído cru sobre essa série.

## 15 · 2026-08-04
Quebrou: `init/prometheus/` estava **vazio** — o serviço apontava o volume para um caminho sem config desde a etapa 02 e reiniciava em loop. Não era ajustar configuração, era criá-la (`prometheus.yml` + `alert_rules.yml`).
Quebrou: Grafana não carregava **nenhum** dashboard, sem erro no log — provisionamento "terminava com sucesso" e a UI ficava vazia. Causa: os `.json` estavam no mesmo diretório do `dashboards.yml`, e o Grafana tenta ler o próprio `.yml` como dashboard. Resolvido movendo os `.json` para `init/grafana/dashboards/`, montado em `/var/lib/grafana/dashboards`.
Quebrou: `cagg_volume_hourly` não tem coluna `total_count` (é `tx_count`) e `completed_threshold` não existe nesta versão do TimescaleDB — o atraso do CAgg sai de `_timescaledb_functions.cagg_watermark(mat_hypertable_id)`. Ambos pegos rodando as queries antes de escrever o painel, não depois.
Quebrou: `E2.4` (etapa 13.5) falhava de forma **sistemática**, não intermitente: 1516s de idade do último sucesso com lag de 0,98s e o worker rodando normalmente. O teste asseria a condição errada desde a origem — o worker só registra sucesso quando há linha nova.
Decidido: alerta de pipeline parado com **condição dupla** (idade > 300s **e** lag > 60s). A versão de E11, só com a idade, acordaria o plantão toda madrugada em ambiente ocioso — e alerta silenciado não detecta o incidente para o qual existe. `E2.4` alinhado à mesma expressão.
Decidido: 2 dos 6 alertas de E11 substituídos por equivalentes do desenho atual — DLQ → `sync_errors_total` (a DLQ era do consumidor CDC) e slot de replicação → `up == 0` (sem CDC não há slot; o risco análogo é o alvo de métricas cair e cegar os outros alertas).
Decidido: `StorageAlto` mantém a expressão de produção (`node_filesystem_*`) mesmo sem `node_exporter` neste ambiente — regra carregada, válida e nunca disparando. Trocar por um proxy local faria o alerta não se parecer com o que rodaria na AWS. Declarado em `alertas.md`.
Decidido: ClickHouse ganhou `:9363/metrics` via `config.d/prometheus.xml`, mesmo padrão do `backup.xml`. Container recriado com conferência de dado antes e depois (10.000.000 linhas nas duas pontas).
Decidido: datasources com UID fixo — dashboard referencia datasource por UID, e UID aleatório quebraria os painéis a cada recriação do container.

## 16 · 2026-08-04
Quebrou: teste `12.6` (MV × raw) falhou no meio da etapa — raw em 10.000.000 e as 2 MVs em 10.000.001. Causa: o `ALTER TABLE ... DELETE` que limpou a transação sintética do teste LGPD **não** removeu o agregado correspondente, porque MV no ClickHouse é gatilho de inserção, não view que recalcula. Mesma classe de armadilha da etapa 12, no sentido inverso. Corrigido removendo e reconstruindo só a fatia divergente (`2026-08-04`/`001`/`pix`) a partir da raw.
Quebrou: `lgpd_erasure_log` não tem coluna `account_hash` (é `document_hash`) — o documento da etapa 09 citava um nome que nunca existiu. Corrigido no texto.
Decidido: o passo 6 **inverteu a conclusão** do documento original. A etapa 09 descrevia a propagação do apagamento ao ClickHouse como pendência; executado, verificou-se que **não há o que propagar** — `accounts_dim` nunca foi criada e `transactions_raw` referencia o titular só por `source_account_id`. Reescrito como verificação com evidência, mantendo o procedimento hipotético para o caso de uma dimensão com PII existir um dia.
Decidido: matriz da auditoria **reescrita, não só conferida** — estava desatualizada em 21 linhas (retrato de antes das etapas 13.5–16). Cada linha reconferida contra o ambiente rodando: containers de pé, backup `20260804-140710F`, `demo-sync-worker.sh` reexecutado. Critérios do PDF § 6.1 de 2/7 para **7/7**.
Decidido: Dictionary vs JOIN medido em **3 padrões de uso**, não só no favorável. Lookup por linha: 0,018s × 0,054s (**2,9×** para o Dictionary). `GROUP BY` sobre 10M e sobre 30 dias: **empate** — a tabela de referência tem 15 linhas e o ClickHouse faz broadcast. O empate está na mesma tabela do ganho.
Decidido: C2b (funil de status) segue **PARCIAL justificado**, não fechado. Medir transição exige tabela de eventos na origem — mudança no sistema transacional, fora do escopo da camada analítica. Limitação declarada no REPORT e no ADR com o caminho descrito.
Decidido: A4b e A5 já estavam atendidos no produto; o gap era documental. O PDF avalia o que está escrito.

## reconciliação da esteira · 2026-08-04
Quebrou: o trabalho pós-auditoria (E0/E1/E2/E4) rodou fora da esteira, sem arquivo de etapa e sem passar por `concluidas/`. O `CLAUDE.md` § 1 apontava para a etapa 13 — já descartada — como "próxima", e a 15 mandava refazer backup que o E4 já tinha entregue.
Decidido: 13 fechada como DESCARTADA (causa provada); criada 13.5 nascendo CONCLUÍDA para registrar E0/E1/E2/E4 retroativamente; 15 reescrita sem backup (só observabilidade/runbook/incidente); criada a 16 para as lacunas PARCIAIS do PDF que nenhuma etapa cobria. `audit.sh` ajustado: 18 etapas, 8 com impeditivo de ficha, rastreio do § 5.2 A.1/A.2 apontando para a 13.5. Removidos 3 diretórios-fantasma vazios (`agent`, `minio-certs;C`, `../trio-data-challenge;C`). Fluxo padrão do `CLAUDE.md` volta a valer: próxima etapa é a 14.

## 17 · 2026-08-04
Decidido: `SUMARIO-EXECUTIVO.md` limitado a 80 linhas **por teste** (`17.2`), não por disciplina. Sumário que cresce deixa de ser sumário, e a regressão é silenciosa — só se percebe quando ninguém mais lê. O limite é o produto, então virou asserção.
Quebrou (premissa, não código): o ESTADO HERDADO da etapa 17 dizia compressão **5,5×**; o valor medido no `REPORT.md` é **5,0×** (23,5× só na tabela, puxado para baixo pelos 1.484 MB de índice). Corrigido no sumário antes de publicar — número em documento executivo é o que a banca cita de volta.
Quebrou (premissa, não código): a esteira registrava `171 pass` desde a etapa 16, mas a suíte completa com o ambiente inteiro de pé dá **174** (155 numerados + 34 do bloco E, menos 3 SKIP de `make`). O 171 era medição feita com parte dos testes de carga-real em SKIP. Baseline corrigido: **186 pass / 0 fail / 3 skip** com o bloco 17.
Decidido: a comparação Aurora × RDS **inverte de sinal** entre os dois cenários — +$26/mês (+10%) no volume atual, −$170/mês (−17%) no cenário 10×. O "~20–30% acima do RDS" da versão anterior era verdade por vCPU e falso como conta mensal: o Serverless v2 escala para baixo em horário ocioso, o RDS Multi-AZ provisiona para o pico 24/7. A recomendação de Aurora foi mantida, mas a justificativa mudou — HA e reader endpoint, **não** preço.
Decidido: incluir a âncora do gerenciado (Timescale Cloud $400–500, ClickHouse Cloud $350–600) mesmo ela enfraquecendo a tese do autogerido. Somados, os gerenciados dão ≈$750–1.100 contra ≈$844 da arquitetura proposta: **não há economia relevante em operar por conta própria neste volume**. Sem essa linha o TCO flutua e não sustenta a pergunta "quanto já se paga hoje".
Decidido: custo evitado do MSK quantificado em **$620/mês (~$7.400/ano)** — 73% do custo total da plataforma no cenário A. O ADR já adiava a fila por argumento operacional; o número é o que torna a decisão defensável numa aprovação de orçamento.
Notado (não é desta etapa): o `README.md` ainda linka `AUDITORIA-E-REPLANEJAMENTO.md` na seção "Documentos que valem a leitura", ao lado dos entregáveis. É andaime de processo apresentado como entregável — a etapa 21 separa as duas coisas.
Quebrou: `audit.sh` teste `A2.1` (esperava 18 arquivos de etapa, achou 23) — as 5 etapas da revisão de entrega quebraram a asserção fixa. **Mesma classe de obsolescência** dos testes `04.6`/`06.3`/`06.4`/`11.6`/`02.2`: avanço legítimo da esteira, não regressão. Corrigido para 23 e o laço de conferência estendido a `17..21`, com o comentário registrando que era 18 até a etapa 16.

## 17.5 · 2026-08-04
Quebrou: **defeito em funcionalidade entregue**, achado ao executar o PASSO 3 da etapa 18 (medir as queries-modelo contra o cluster, em vez de copiar SQL). O `dict_institutions` resolvia **33,55%** do volume: o seed do legado gerava `001`..`015` (`lpad(g,3,'0')`) e o seed de transações usa códigos reais (`237`, `341`, `104`...). Só o `001` coincidia — e como `001` é o topo da Zipf, a resolução parcial parecia dado. A API já servia `"institution_name":"desconhecida"` para 66% das instituições.
Quebrou: o que escondeu o defeito por 6 etapas foi o comentário do próprio seed — *"mesma cardinalidade... para o Dictionary casar 1:1"*. **A cardinalidade estava certa (15=15); o valor é que não casava.** Toda verificação anterior (dictGet devolve algo, 15 elementos em `system.dictionaries`, ref-sync recarrega) passava.
Decidido: corrigir o **seed do legado**, não o de transações — códigos reais de bancos brasileiros são o dado mais realista e já sustentam a Zipf, os outliers de latência e todas as medições do REPORT. A direção inversa exigiria refazer os 10M. Confirmado com o usuário antes de executar (Seção 5).
Decidido: `UPDATE` in-place em vez de recarga. As 2 FKs (`institution_configs`, `legacy_accounts`) referenciam `partner_institutions(id)`, **não** `code` — trocar o código não move linha dependente. 480 configs e 80.000 contas intactas.
Quebrou (consequência): os 3 números de Dictionary vs JOIN do `REPORT.md` estavam medidos sobre dado que não casava. Remedidos: lookup por linha **4 ms × 15 ms (3,75×)**, `GROUP BY` 10M **11 ms × 147 ms (13,4×)**, `GROUP BY` 90 dias **18 ms × 72 ms (4,0×)`. **Os dois "empates honestos" que a etapa 16 declarou eram artefato do defeito** — um `dictGet` que devolve default sai pelo caminho curto e não paga o custo da resolução, e a JOIN, que também não achava nada, parecia competitiva.
Decidido: a tabela antiga do REPORT foi **substituída com explicação**, não apagada. O REPORT é o documento que a banca usa para conferir método; sumir com uma medição errada sem dizer por quê é pior que o erro.
Quebrou: teste `16.9` asseria o literal `"0,018"` no REPORT — refém de um valor específico, quebrava a cada remedição legítima. Reescrito para asserir a **propriedade** (tabela com os 2 caminhos e unidade de tempo).
Quebrou: teste `14.4` **revertia a correção silenciosamente**. Ele faz UPDATE em `partner_institutions`, confere a propagação e restaura — mas restaurava o literal `'Instituição Parceira 1'`. Passava (a propagação funciona) enquanto desfazia o conserto do `001` a cada execução. Corrigido para **ler o valor original do banco** antes do UPDATE. `14.19`, que grepava `"Institui"`, passou a comparar com o nome que está no legado.
Notado: `ref-sync` detectou a mudança sozinho pelo `invalidate_query` e recarregou no ciclo seguinte, sem intervenção — o mecanismo do ADR funcionou como desenhado.
Notado: `MSYS_NO_PATHCONV=1` é necessário para `docker exec ... -f /tmp/x.sql` no Git Bash, senão o caminho do container vira caminho do Windows.

## 18 · 2026-08-04
Decidido: as 3 queries-modelo do guia são **executadas pelos testes** (`18.10a/b/c`), não só citadas. Query em documento que nunca rodou é a forma mais fácil de publicar SQL quebrado — e foi exatamente rodando que se achou o defeito do Dictionary.
Decidido: os limites de query são testados **falhando de verdade** (`18.11`, `18.11b`), com as mensagens reais capturadas do cluster (`TIMEOUT_EXCEEDED`, `TOO_MANY_ROWS`, `MEMORY_LIMIT_EXCEEDED`). Limite documentado que não arma é texto.
Quebrou (ao escrever o guia): `countMerge(settled_count)` dá `Aggregate function count requires zero or one argument` — a coluna foi gravada com `countIf`, então lê-se com `countIfMerge`. O sufixo `-Merge` tem que casar com a função que gravou o estado. Foi para o guia como armadilha nº 2.
Quebrou (ao escrever o guia): `dictGet` com `toUInt64(source_institution)` não resolve nada — a chave é `String` com layout `COMPLEX_KEY_HASHED` e exige `tuple(...)`. Foi para o guia.
Quebrou (ao escrever o guia): `sum(countMerge(x))` dá `ILLEGAL_AGGREGATION` — mesma armadilha da etapa 14, reencontrada de forma independente ao contar as MVs. Resolve com `-Merge` na subconsulta e `sum` fora.
Decidido: contraexemplo de poda de partição **medido**, não afirmado — `WHERE toString(created_at) LIKE '2026-07-01%'` lê 6.094.848 linhas em 216 ms contra 8.192 linhas em 6 ms da forma correta. 36× mais lento, 744× mais dado, mesma resposta.
Decidido: Hex declarado como **não executado**. Não há conta neste ambiente; o guia traz o caminho de conexão e a convenção (notebook contra MV, nunca contra a raw), com a limitação escrita. Mesmo padrão do `StorageAlto` sem `node_exporter` na etapa 15.
Decidido: o trade-off de `accounts`/Q2 ganhou seção própria no `REPORT.md`, não só no guia. Q2 (reconciliação) só é respondível no TimescaleDB porque PII não vai ao ClickHouse — é limitação assumida que ninguém tinha declarado.

## 19 · 2026-08-04
Decidido: perfil criado por **RBAC via SQL**, não por `users.d/`. O compose já traz `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT: 1`, e `/var/lib/clickhouse/access/` persiste no volume — usuário criado por SQL sobrevive à recriação do container (confirmado: `analytics_ro` seguiu de pé depois do `up -d` que montou a named collection). Evita o risco que o ROLLBACK da etapa previa, de recriar container só para aplicar arquivo de usuários.
Quebrou: `CREATE QUOTA ... TO p_analytics_ro` dá `UNKNOWN_ROLE` — quota se prende a **role ou usuário**, não a settings profile. Corrigido para `TO analytics_reader`.
Decidido: `readonly = 1` no perfil, não só limites. Sem isso o cliente passa `--max_rows_to_read=999999999999` e afrouxa o próprio teto — limite que o usuário ajusta não é limite. Testado: devolve `Cannot modify 'max_rows_to_read' setting in readonly mode (READONLY)`.
Decidido: os testes de perfil exercitam a **negação** (`19.9`, `19.9b`, `19.9c`), não a permissão. Permissão passa por acidente; negação é o que o perfil existe para fazer.
Decidido: segredo do Dictionary sai do DDL via **named collection** (`NAME legado_pg`), não por variável de ambiente. Validado criando um dicionário de teste com a sintaxe nova **antes** de trocar o de produção — o DDL do repositório é o que roda no `init`, e publicar sintaxe não testada seria repetir o erro da query ilustrativa de S04 (etapa 12).
Notado: o Dictionary vivo continuava com a definição antiga (credencial inline) mesmo após a recriação do container — `init/` só roda em volume novo. Precisou de `DROP`/`CREATE` explícito para o schema versionado e o estado real coincidirem. Contagem conferida antes e depois: 10.000.000 nas 3 pontas, resolução em 100%.
Decidido: `pgaudit` **não** está disponível na imagem fixada (fora de `pg_available_extensions`) e trocar imagem viola a Seção 2. Trilha implementada com função `SECURITY DEFINER` + gatilho append-only — mesma classe de decisão do `percentile_agg` na etapa 08. O limite está declarado: quem tiver `SELECT` direto em `accounts` (hoje o superusuário `trio`) lê sem rastro, e isso só fecha em produção com `REVOKE` + `pgaudit` no parameter group do Aurora.
Decidido: a trilha grava **`rows_returned`** e exige **finalidade**. Log que só diz "alguém consultou accounts" não distingue o suporte olhando 1 titular de uma extração de 80.000; acesso sem propósito declarado é o que a LGPD art. 37 manda não existir.
Decidido: PCI-DSS declarado **fora de escopo, explicitamente**. Não há PAN/CVV em nenhuma tabela — as transações são Pix/TED/boleto. Dizer que não se aplica, e o que mudaria se cartão entrasse, vale mais do que omitir a sigla.
Decidido: `pii_reader`, `ops` e `auditor` ficam como contrato escrito, não implementados — exigiriam separar credencial de serviço em todos os componentes. `analytics_ro` é a prova de que o modelo aplica; a matriz é o contrato.

## 20.5 · 2026-08-05
Quebrou: **segundo defeito de produto achado medindo** — o sync-worker perdia dados em silêncio. 60.000 linhas num único `INSERT` → 50.000 no destino, worker parado, lag congelado, **zero erro no log**. Causa: `now()` é fixo por statement no PostgreSQL (as 60.000 têm o **mesmo** `updated_at`), o `LIMIT 50000` corta no meio desse instante, e o filtro `updated_at > limite` descartava o excedente a cada ciclo, para sempre.
Quebrou: o comentário do próprio código previa o sintoma — *"se este número for sempre igual ao lote inteiro, o watermark travou"*. O diagnóstico estava escrito; a guarda, não.
Decidido: corrigir a **causa** (watermark composto `(updated_at, id)`), não mover o patamar. Subir `BATCH_MAX_ROWS` faria o teste passar e deixaria o deadlock esperando um lote maior. Confirmado com o usuário antes de mexer (Seção 5).
Quebrou: **a primeira correção não funcionou** e travou o pipeline por outro caminho. Trocar o predicado e o filtro pela tupla não bastou — o `overlap` recua o timestamp, recuar obriga a começar do `id 0`, e aí o `LIMIT` se esgotava nas 50.000 **já escritas**, que o filtro descartava. Ciclo terminava sem escrever nada. Só ficou correto **separando as duas leituras**: retomada exata a partir de `(wm_ts, wm_id)` primeiro (é ela que garante progresso) e overlap só quando a retomada não encheu o lote.
Decidido: watermark = `max()` do **par**, não `linhas[-1]`. Com as duas leituras o lote deixa de ser monotônico antes da reordenação, e a última linha nem sempre é a maior — usar `linhas[-1]` retrocederia o watermark em ciclos que varrem o overlap.
Notado: overlap e mutação reconferidos após a reestruturação — `pending`→`settled` propaga, as 2 versões convivem na raw e `FINAL` colapsa. A correção não quebrou o que já funcionava.

## 20 · 2026-08-05
Quebrou: **o teste de saturação original não saturava**, e quase virou conclusão errada. Os 4 patamares (500 → 5.800/s) passaram com zero perda e lag < 7s — o script teria reportado "aguenta 5.800/s", verdadeiro e enganoso: `INSERT` em massa escreve 5.800 linhas em 0,43s e nenhum patamar chegava perto de `BATCH_MAX_ROWS`. Foi preciso o patamar de **60.000** (acima do lote) para o limite real aparecer — e foi ele que revelou o bug da 20.5.
Decidido: patamar de 60.000 fica **permanente** no script, com coluna de entrega **por patamar**. Conferir só o total no fim mascara qual patamar perdeu linha.
Decidido: o limite real do pipeline **não é vazão** — é o tamanho do lote dentro de um mesmo `updated_at`. Enquanto a rajada couber em `BATCH_MAX_ROWS`, drena em uma passada; acima disso são 2 ciclos e o lag sobe. É configuração, não arquitetura.
Decidido: `EXCHANGE TABLES`, não `RENAME` em dois tempos. O `RENAME` tem um instante em que a tabela **não existe** e toda consulta falha; `EXCHANGE` é atômico. A resposta anterior das 5 perguntas citava `RENAME`.
Decidido: os 2 procedimentos nascem das **cicatrizes reais** (duplicação de 10M na etapa 12, divergência MV/raw na 16), citadas por etapa e sintoma. Procedimento que nasce de erro cometido é mais defensável que procedimento copiado.
Decidido: cenário de Q4 planta 3 cobranças idênticas e detecta **2 pares consecutivos** (1→2, 2→3), não 3 — a janela é entre transações consecutivas. Separa "não achou porque não existe" de "não achou porque está errada".
Decidido: **não** subir Keeper local para demonstrar HA. Três Keepers na mesma máquina demonstram configuração, não a propriedade — failover real exige derrubar nó e provar que a leitura continua. Plano escrito + custo calculado é mais honesto que encenação.
Notado: o RBAC é estado à parte na migração para `Replicated*` — vive em `/var/lib/clickhouse/access/`, não nas tabelas, e precisa de `ON CLUSTER` ou o Data Champion autentica numa réplica e falha na outra.

## 21 · 2026-08-05
Decidido: `CLAUDE.md` → `docs/METODO-DE-EXECUCAO.md` com preâmbulo que **assume a metodologia**. O PDF condena uso de IA *sem revisão crítica*; o arquivo é a prova documental da revisão — escopo travado, arquitetura travada, política de impedimento. Esconder o arquivo seria mais suspeito que exibi-lo, e o argumento mais forte está na esteira: 2 etapas nasceram de defeito achado **medindo** (17.5, 20.5) e 1 foi descartada com causa-raiz provada (13).
Decidido: `git mv` em tudo, nunca `rm` + `add` — o valor de "30 commits com processo real" depende de o histórico atravessar o rename. Nenhum documento de processo apagado; `21.3b` guarda isso.
Quebrou: `audit.sh` `A1.10` passou a falhar por motivo **legítimo** — o arquivo ganhou 24 linhas de preâmbulo de entrega e passou de 110. Em vez de subir o teto e perder a guarda, o teste passou a medir **só as seções de regra** (a partir de `## 1. Operação`), que é o que de fato pesa no contexto lido a cada etapa.
Quebrou: `E1.4` apontava para `PREMISSAS-VERIFICADAS.md` na raiz. Só falha **depois** do `git mv` — não é achável por leitura.
Quebrou: `A7.7` e `01.4` asseriam `wip/trio-challenge`. Só falham **depois** do rename. As duas confirmam na prática o que o ESTADO HERDADO avisava: é a etapa que quebra se for feita no automático.
Decidido: referências **históricas** mantidas com o nome antigo. `LOG-EXECUCAO.md`, `99-validacao-final.md` e as etapas em `concluidas/` citam `CLAUDE.md` e `AUDITORIA-E-REPLANEJAMENTO.md` na raiz — corrigi-las seria falsificar o registro do que era verdade naquele momento. Só referência **viva** foi atualizada.
Decidido: branch `wip/trio-challenge` → **`main`**, com autorização explícita do usuário (a Seção 8 exige instrução explícita para mexer em `main`). Operação local, sem remote, 30 commits intactos. Seção 8 atualizada registrando a mudança e a autorização.
Notado: varredura de segredo achou `desafio-3/backup/minio-certs/private.key` no histórico (commitada em `f8a0e2e`, retirada em `17a90dc` — remover depois não apaga do histórico). É chave de certificado **autoassinado local**, que não abre nada. **Declarada** em `SEGURANCA-E-GOVERNANCA.md` § 3 em vez de reescrever o histórico: `filter-branch` custaria o rastro inteiro do processo para remover risco nulo. O critério de quando a decisão seria a oposta está escrito junto. `.env` nunca foi commitado.
