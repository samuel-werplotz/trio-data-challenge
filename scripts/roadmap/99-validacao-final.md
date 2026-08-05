# 99 — VALIDAÇÃO FINAL  [carga-real]

## ORIGEM
PDF § 6.1 "Critérios de Aceitação Mínimos" + PDF § 7 "Apresentação Técnica"; `../vault-estudo/06-Especificacao/S10-Conformidade-PDF.md` (rastreio requisito-a-requisito — **conferir inteiro antes de entregar**); `../vault-estudo/06-Especificacao/ESPECIFICACAO.md` § Limitações assumidas e documentadas; `../vault-estudo/03-Fluxo-Desenvolvimento/E13-Apresentacao.md` § O teste do zero · § O README raiz · § As 5 perguntas

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído

## ESTADO HERDADO
Verificado ao fechar a etapa 16 (a última antes desta; a nota "preenchido pela 15" era anterior à criação da 16):
- **Matriz de rastreabilidade da auditoria (§ FASE 3) atualizada contra o ambiente rodando**, não contra o plano: **nenhuma linha em FALTA**. Os 7 critérios de aceite do PDF § 6.1 estão **7/7 OK** (eram 2/7 na auditoria). Teste `16.11` guarda a ausência de FALTA.
- **Única linha PARCIAL remanescente: C2b** (funil de status). A MV mede estado atual, não transição, porque a origem sobrescreve `status` sem guardar histórico — fechar exigiria mudar o schema do sistema transacional. Limitação declarada em `REPORT.md` e `ADR.md`, com o que seria necessário para medir de verdade. **É PARCIAL justificado, não pendência.**
- **As 5 lacunas da etapa 16 foram fechadas**: A4b (P95/P99 por instituição, com saída real no REPORT), A5 (retenção + comando `alter_job(1007, scheduled => true)`), B3 (`migration-analysis.md` de 60 → **210 linhas**, 4 sub-itens), C2b (declarada), C3 (Dictionary vs JOIN **medido** — números **substituídos na 17.5**: 4 ms × 15 ms, **3,75×** no lookup por linha, após a correção do seed que levou a resolução de 33,55% a 100%).
- **LGPD executado de ponta a ponta** (era "procedimento futuro" desde a etapa 09). Resultado que inverteu a suposição do documento: **o ClickHouse não guarda PII** — só `source_account_id` —, então não há o que propagar. Verificado por varredura de `system.columns` e por teste com conta sintética, já removida.
- **`demo-sync-worker.sh` reexecutado** e funcionando: INSERT→`pending`, UPDATE→`settled`, 2 versões convivendo sem `FINAL`, `OPTIMIZE` colapsando, idempotência confirmada.
- **Backup reconferido**: `full backup: 20260804-140710F`, status ok.
- `run_all.sh`: blocos 01–16, **171 pass / 0 fail / 3 skip** (os 3 SKIP são `make` ausente neste Windows). `audit.sh`: 83 pass / 0 fail / 2 warn / 1 skip.
- **Dado íntegro nas 3 pontas**: `transactions` 10.000.000; `transactions_raw` 10.000.000; **e as 2 MVs agregadas também em 10.000.000** — conferir `countMerge` ao validar, não só a raw (ver desvio 3 da etapa 16).
- Containers de pé: 11 (`timescaledb`, `postgres-legado`, `clickhouse`, `minio`, `sync-worker`, `ref-sync`, `api`, `grafana`, `prometheus`, 2 `pg-exporter`).

## ESCOPO
Faz: sequência completa do zero cronometrada, README raiz com os tempos reais, `REPORT.md` consolidado, roteiro de demonstração e ensaio das 5 perguntas previstas.
Não faz: não corrige funcionalidade — o que quebrar aqui volta para a etapa dona do problema; não reescreve etapa já concluída.

## PASSOS
1. Rodar a sequência do zero, cronometrando cada passo: `nuke` → `up` → `seed` → `indexes` → `policies` → `backfill` → `pipeline` → `check`.
2. Preencher a coluna `evidência` da tabela dos 7 critérios abaixo com arquivo, comando ou número real.
3. Conferir o mapa requisito-do-PDF → arquivo-entregue, item a item.
4. Escrever o README raiz na ordem de E13: o que é (3 linhas) → como subir (1 comando) → quanto tempo cada passo leva → como verificar → mapa do repositório → link para cada documento.
5. Consolidar o `REPORT.md`: tabela antes/depois das queries, taxa de compressão, número do sub-segundo do ClickHouse, RTO/RPO medidos.
6. Escrever o roteiro de demonstração e ensaiar as 5 perguntas.
7. Rodar `run_all.sh` inteiro pela última vez.

## CRITÉRIOS DE ACEITE
- [ ] Sequência do zero completa sem intervenção manual, com tempo de cada passo registrado
- [ ] Os 7 critérios do PDF § 6.1 com evidência preenchida
- [ ] README raiz responde as 6 perguntas de E13
- [ ] `REPORT.md` sem número inventado — tudo medido
- [ ] `run_all.sh` sem nenhum `FAIL`
- [ ] As 5 limitações assumidas estão declaradas no repositório entregue

---

## Os 7 critérios de aceitação mínimos (PDF § 6.1)

| # | Critério (literal do PDF) | Etapa que entrega | Evidência |
|---|---|---|---|
| 1 | `docker-compose up -d` sobe todo o ambiente sem erros | 02, 03 | `<PREENCHER>` |
| 2 | Scripts de seed rodam e populam os bancos com volume relevante | 05, 10 | `<PREENCHER>` |
| 3 | Queries do Desafio 1 executam com sucesso e têm `EXPLAIN ANALYZE` documentado | 06, 07 | `<PREENCHER>` |
| 4 | Pelo menos um pipeline (TimescaleDB → ClickHouse) funciona end-to-end de forma demonstrável | 12, 13.5 | `<PREENCHER>` |
| 5 | Pelo menos um dashboard Grafana está funcional consultando ClickHouse | 15 | `<PREENCHER>` |
| 6 | Documentação cobre decisões técnicas com justificativas | 09, 14, 15, 16 | `<PREENCHER>` |
| 7 | Análise de migração PostgreSQL → Aurora está presente e fundamentada | 10, 16 | `<PREENCHER>` |

## Mapa requisito → arquivo entregue

| Desafio | Requisito | Arquivo |
|---|---|---|
| 1 | Schema TimescaleDB | `desafio-1/schemas/01_timescale_schema.sql`, `init/timescaledb/01_schema.sql` |
| 1 | Seed de volume relevante | `desafio-1/seed/generate_transactions.py` |
| 1 | Queries + `EXPLAIN` antes/depois | `desafio-1/queries/`, `desafio-1/queries/explains/qN_{before,after}.txt` |
| 1 | Índices | `init/timescaledb/03_indexes.sql` |
| 1 | CAggs, compressão, retenção | `init/timescaledb/04_caggs_policies.sql` |
| 1 | LGPD / sanitização de PII | `desafio-1/lgpd-sanitization.md` |
| 1 | Schema legado + bloat | `desafio-1/schemas/02_legacy.sql` |
| 1 | Migração para Aurora | `desafio-1/migration-analysis.md` |
| 1 | Consolidação de medições | `desafio-1/REPORT.md` |
| 2 | Schema ClickHouse (engine, MVs, Dictionary) | `init/clickhouse/01_schema.sql` |
| 2 | Pipeline TimescaleDB → ClickHouse (micro-batch por watermark) | `desafio-2/pipeline/sync-worker/` |
| 2 | Abordagem CDC avaliada e descartada (artefato da decisão) | `desafio-2/pipeline/consumer/`, profile `cdc-experimento` |
| 2 | Ref-sync e API | `desafio-2/pipeline/ref_sync.py`, API FastAPI |
| 2 | Diagramas | `desafio-2/diagrams/` |
| 2 | Decisões arquiteturais | `desafio-2/ADR.md` |
| 3 | Backup dos **3** bancos (tipo, frequência, retenção, destino AWS) | `desafio-3/backup/`, `desafio-3/backup/README.md` |
| 3 | Recovery com perda simulada e 3 contagens | `desafio-3/backup/restore-drill.sh` |
| 3 | Dashboards e alertas (métrica, threshold, severidade, ação, CloudWatch/SNS) | `desafio-3/grafana/`, `init/grafana/provisioning/` |
| 3 | Runbook do storage em 92% | `desafio-3/runbook.md` |
| 3 | Resposta a incidente SEV-1 | `desafio-3/incident-response.md` |
| — | Ambiente | `docker-compose.yml`, `Makefile`, `.env.example` |
| — | Apresentação | `README.md`, `docs/` |

## Limitações assumidas (declarar antes que perguntem)

| Limitação | Razão | Onde está documentada |
|---|---|---|
| Funil de status mede estado, não transição | A origem não guarda histórico de mudanças | S04 → `init/clickhouse/01_schema.sql`, `ADR.md` |
| `external_id` sem unicidade global | Índice único sobre 365 chunks é caro demais; unicidade é do sistema de origem | S01 → `01_schema.sql`, `REPORT.md` |
| Sem chave estrangeira em `transactions` | FK mataria a performance da carga de 10M; prática de alto volume | S01 → `01_schema.sql` |
| Plano B do CDC perde `DELETE` | Watermark por `updated_at` não captura exclusão | `ADR.md` (registrado mesmo se o plano B não for acionado) |
| Bloat do legado é induzido | Precisamos de um problema real para o dashboard mostrar — declarado abertamente | `migration-analysis.md`, dashboard do legado |
| P95/P99 de latência não é materializado em CAgg | `timescaledb_toolkit` (que traz `percentile_agg`) não existe na imagem fixada `timescale/timescaledb:latest-pg16`; trocar a imagem violaria a reprodutibilidade. Percentil não é somável, então não há como materializá-lo sem o esboço TDigest. | S03 § plano B → `04_caggs_policies.sql`, `REPORT.md` § Limitação declarada |
| Retenção de 90 dias do raw fica desligada | O desafio pede 12 meses de dado E retenção de 90 dias; aplicar a política apagaria 9 meses. A política existe e é a correta para produção. | `04_caggs_policies.sql`, `retention-demo.sh`, `REPORT.md` § Retenção |
| `failed_count`/`total_count` do CAgg de latência não medem falha | O CAgg filtra `WHERE settled_at IS NOT NULL` e nenhuma transação `failed` tem `settled_at` — as colunas de S03 são estruturalmente 0. Taxa de falha vem do `cagg_volume_hourly`. | `04_caggs_policies.sql` (comentário no DDL), `REPORT.md` § A armadilha do `failed_count` |

## Desvios do plano registrados durante a execução

| Etapa | Desvio | Razão | Resolução |
|---|---|---|---|
| 07 | Testes `04.6` e `06.3` do `run_all.sh` viraram obsoletos | Ambos afirmavam "nenhum índice além dos implícitos em `transactions`", verdadeiro nas etapas 04 e 06. A etapa 07 cria índices **por design** (é o objeto da etapa), então a asserção deixa de valer por avanço legítimo da esteira, não por regressão. | Reescritos para asserir a **pré-condição da própria etapa** em vez de um estado global: passam a exigir que o número de índices seja o esperado *naquele ponto do roadmap*, checando a ausência dos índices nomeados de `03_indexes.sql` em vez de contar o total. `qN_before.txt` continua sendo a evidência de que a medição "antes" foi feita sem índice. |
| 07 | `reconciliation_events` regerado (dado da etapa 05 substituído) | O gerador produzia divergência como percentual do valor (86% das linhas divergiam, não ~8%) e `reconciled_at = now()` para todas as linhas (filtro de 30 dias não excluía nada). As duas coisas invalidavam a premissa de seletividade do índice parcial de Q2 (S06) e o teste de exclusão de chunk. | `load_reconciliation()` corrigido; só `reconciliation_events` foi truncado e recarregado (os 10M de `transactions` intactos); medições de Q2 refeitas do zero — `before` (com índices removidos) e `after` — sobre o dado corrigido. Documentado em `desafio-1/REPORT.md` e `MEDICOES.md`. |

| 08 | `percentile_agg` de S03 substituído pelo plano B do próprio S03 | `timescaledb_toolkit` ausente da imagem fixada (verificado: fora de `pg_available_extensions` e sem binários no container). As alternativas — imagem `-ha` ou build do toolkit — esbarram na Seção 2 do `CLAUDE.md` (não trocar imagens fixadas) e arriscariam o volume com os 10M já carregados. | CAgg 2 materializa só o que é somável (contagens, `sum`, `sum²`, min, max); P95/P99 saem de `percentile_cont` na view `v_settlement_latency_percentiles` sobre o raw. Trade-off comentado no DDL e no `REPORT.md`. Decisão confirmada com o usuário antes de implementar. |
| 08 | Teste `06.4` do `run_all.sh` virou obsoleto | Asseria "0 continuous aggregates", verdadeiro até a etapa 07. A etapa 08 cria os 2 CAggs **por design** — mesma classe de obsolescência dos testes `04.6`/`06.3` na etapa 07: avanço legítimo da esteira, não regressão. | Reescrito para asserir a **evidência** em vez do estado global: `q1_before.txt` não pode conter `_materialized_hypertable`, o que prova que a medição "antes" varreu `transactions` e não um CAgg. |
| 08 | Teste `08.3` do plano esperava 1 política de retenção; existem 3 | O `PASSO 7` da própria etapa acrescentou as retenções de 2 anos sobre os 2 CAggs (PDF § 3.2 A.5), depois que a tabela de testes da etapa já estava escrita com o número antigo. | `08.3` passou a exigir 3 (1 raw + 2 CAggs) e ganhou o par `08.3b`, que separa o que importa: a do raw **parada**, as dos CAggs **ligadas**. |
| 08 | `retention-demo.sh` em `desafio-1/scripts/`, não em `scripts/` | O `PASSO 8` da etapa dizia `scripts/retention-demo.sh`, mas o `Makefile` (contrato de S08, alvo `demo-retention`) aponta para `desafio-1/scripts/retention-demo.sh`. | Seguido o caminho do Makefile — S08 é contrato, a redação do passo não. |
| 10 | Teste `06.2` do `run_all.sh` quebrou (esperava 4 arquivos `Buffers:`, achou 6) | `06.2` usava `*_before.txt` sem prefixo — a etapa 10 criou `legacy_q1_before.txt`/`legacy_q2_before.txt` no mesmo diretório `desafio-1/queries/explains/`, e ambos também contêm `Buffers:`. Regressão silenciosa por avanço legítimo de escopo, mesma classe dos ajustes em `04.6`/`06.3`/`06.4`. | Glob restrito a `q[1-4]_before.txt`, escopando o teste às 4 queries do desafio 1 (TimescaleDB) e excluindo as `legacy_qN` do desafio 1/legado. |
| 10 | Legacy Q1 não mudou de tempo após `ANALYZE` | O gargalo previsto por S07 (`Nested Loop` por estatística desatualizada) não se manifestou nesta escala — o planner já escolhia `Hash Join` mesmo com a estimativa de linhas errada (509.298 em vez de 80.000). | Medido e reportado como está: o ganho real foi na precisão da estimativa (509.298→80.000, exata), não no tempo. Documentado em `migration-analysis.md` em vez de forçar a narrativa esperada — mesmo espírito do "índice que não melhorou" (Q2, etapa 07). |
| 11 | Colunas `AggregateFunction(avg\|quantile, Float32)` de S04 não batiam com o tipo real produzido pela MV | `settlement_seconds` é `Nullable(Float32)` (NULL para transação não liquidada); `avgState`/`quantileState` sobre coluna nullable produzem `AggregateFunction(_, Nullable(Float32))`, não `AggregateFunction(_, Float32)` como o DDL literal de S04 declarava — `CREATE MATERIALIZED VIEW` falhava com `CANNOT_CONVERT_TYPE`. Bug real no schema de origem, não do plano. | `avg_settle_seconds` (em `daily_by_institution`) e `avg_seconds`/`p50_seconds`/`p95_seconds` (em `status_funnel`) redeclarados como `AggregateFunction(_, Nullable(Float32))` em `init/clickhouse/01_schema.sql`, com comentário explicando o motivo. Resto do schema idêntico a S04. |
| 11 | `docker compose --profile core up` falha (`service "grafana" depends_on undefined service "prometheus"`) | Bug pré-existente na config: `grafana` está em `profiles: ["core","full"]` e depende de `prometheus`, que só está em `profiles: ["full"]`. Não é desta etapa (nenhum PASSO mexeu em `docker-compose.yml`) e os testes 02.1/02.2 não pegam porque usam `--profile full`. | Contornado sem editar o compose (fora do escopo, Seção 2): `clickhouse` subido por nome de serviço (`docker compose up -d clickhouse`), que ignora o filtro de perfil. Registrado aqui para não ser redescoberto do zero numa etapa futura que precise do perfil `core`. |
| 12 | `INSERT SELECT` de backfill das 2 MVs duplicou tudo (20M agregados em vez de 10M) | As MVs (criadas na etapa 11) são gatilho de inserção e já estavam ativas quando o backfill do raw rodou — capturaram sozinhas cada um dos 12 blocos mensais. O `INSERT SELECT` manual, rodado depois, duplicou o que a MV já tinha inserido em tempo real. Confirmado com `countMerge` agrupado: 20.000.000 antes da correção. | Truncadas as 2 tabelas de agregação (raw preservado) e `INSERT SELECT` rodado uma única vez, sem novo `INSERT` no raw no meio — `countMerge` bateu 10.000.000 nas duas. `scripts/backfill-clickhouse.sh` corrigido para checar se a tabela já tem linhas antes de rodar o `INSERT SELECT`, evitando repetir o erro numa reexecução. |
| 12 | Query ilustrativa de S04 (`countIfMerge(cnt)`) não roda contra o schema real | `status_funnel.status` é coluna do `GROUP BY`, não um filtro pré-embutido em `cnt` (gravado com `countState()` puro, não `countIfState`) — `countIfMerge` sobre esse estado dá `ILLEGAL_TYPE_OF_ARGUMENT`. Erro pego rodando a query de verdade contra o schema real, não copiando o SQL de S04 sem testar. | `desafio-1/queries/grafana_pix_24h_vs_d1.sql` reescrita: "sucesso" é derivado filtrando `status='settled'` na leitura (`sumIf` sobre valor desagregado por `countMerge`), não pré-computado na agregação. Resultado: mediana 7-8ms, muito abaixo dos <1000ms exigidos. |
| 12 | Teste `11.6` do `run_all.sh` quebrou (esperava `transactions_raw` vazia) | A etapa 12 popula `transactions_raw` por design — mesma classe de obsolescência dos ajustes em `04.6`/`06.3`/`06.4`/`10-06.2`. | Reescrito para verificar que a tabela existe e responde a `count()`, sem exigir 0 linhas — o dado (vazio antes da 12, cheio depois) não é mais o que o teste garante. |
| 13 | Etapa inteira **descartada**, não executada | `publish_via_partition_root` não funciona sobre hypertable: ela não é tabela particionada nativa (`relkind='r'`, chunk com `relispartition='f'`), então escritas em chunk nunca entram na publication. Provado isolando a decodificação lógica sem o Debezium no circuito — `peek_binary_changes` devolveu 0 mudanças; adicionar 1 chunk à publication devolveu 6 imediatamente. Causa estrutural: uma premissa vinda do vault foi promovida a contrato de arquitetura sem nunca ter sido testada. | Substituída pela etapa 13.5 (micro-batch por watermark), abordagem que o PDF § 4.2 A.1 lista em pé de igualdade com CDC. Debezium nunca foi requisito. Consumidor e `demo-mutation.sh` preservados no profile `cdc-experimento` como artefato da decisão, e o experimento vira o insumo da justificativa escrita que o PDF cobra. Diagnóstico completo em `AUDITORIA-E-REPLANEJAMENTO.md`. |
| 13.5 | Etapa executada **fora da esteira**, sob a nomenclatura E0/E1/E2/E4 | Após a auditoria, o trabalho seguiu o roadmap E0–E7 do `AUDITORIA-E-REPLANEJAMENTO.md` § 4.6 em vez dos arquivos de `scripts/roadmap/`. Quatro commits (`4051e42`, `bb29020`, `f8a0e2e`, `17a90dc`) entregaram estabilização, verificação de premissas, sync-worker e backup sem arquivo de etapa, sem `ESTADO HERDADO` e sem passar por `concluidas/`. O orquestrador ficou apontando para a etapa 13, já descartada. | Esteira reconciliada: criada a etapa `13.5-sync-worker-e-backup.md` nascendo CONCLUÍDA, que registra retroativamente o que E0/E1/E2/E4 entregaram. A etapa 15 foi reescrita sem a parte de backup (entregue na 13.5) e a 16 foi criada para varrer as lacunas do PDF. `audit.sh` atualizado para 18 etapas e com o rastreio do § 5.2 A.1/A.2 apontando para a 13.5. |
| 14 | Teste `02.2` do `run_all.sh` atualizado (8/11 → 10/13 serviços) | `api` e `ref-sync` estavam no profile `pendente` por não terem Dockerfile; esta etapa os implementou e devolveu aos profiles `core`/`full`. Os números antigos descreviam o esqueleto, não a entrega — mesma classe de obsolescência por avanço legítimo dos ajustes em `04.6`/`06.3`/`06.4`/`11.6`. | `02.2` passou a exigir `core=10` e `full=13`, com o comentário registrando que os números anteriores valiam enquanto os dois serviços eram esqueleto. `docker compose --profile core config` e `--profile full config` validados sem erro. |
| 14 | Query do endpoint `/institutions/{code}/health` reescrita com subconsulta | A forma direta que o desenho pedia (`sum(countMerge(cnt))`, `sumIf(countMerge(cnt), ...)`) é `ILLEGAL_AGGREGATION` no ClickHouse — não se aninha função de agregação dentro de outra. Pego rodando contra o schema real, mesma classe do erro da query ilustrativa de S04 na etapa 12. | Merge dos estados na subconsulta (agrupando por `hour, type, status` + colunas de estado), soma na consulta externa. Resultado conferido contra a raw: P95 55.604s vs 57.407s e avg 6.215 vs 6.215 — o desvio da P95 é o esperado de `quantile` aproximado sobre estado pré-agregado por hora. |
| 14 | `dict_institution_config` **não** implementado | `Container-Ref-Sync.md` lista dois dicionários a sincronizar, mas só `dict_institutions` existe no schema de S04. Criar o segundo seria mudança de schema — matéria que a Seção 5 do `CLAUDE.md` manda travar e esperar, não decidir sozinho. | Escopo do `ref-sync` limitado ao Dictionary existente, com o motivo comentado em `config.py`. O worker é parametrizado por `REF_DICTIONARY`/`REF_SOURCE_TABLE`, então incluir o segundo depois é configuração, não reescrita. Registrado nas premissas da etapa. |
| 14 | Testes `14.3`/`14.15` reescritos após instabilidade intermitente | A 1ª versão comparava dois **acertos** de cache (~0,006–0,010 ms cada), onde o ruído de agendamento decide qual é menor — falhava ~1 vez a cada 4 execuções com o cache funcionando. Agravado por a API rodar com 2 workers uvicorn, cada um com cache em memória próprio: a 2ª chamada podia cair no worker sem a entrada. | Corrigido nas duas pontas, não só no teste: comparação passou a ser **miss × hit** (exige `hit < miss/10`) com chave inédita por execução (`$$`), e a API passou a 1 worker por decisão de desenho — cache por processo torna cada worker extra um cache independente. Estável em 12 repetições isoladas e 3 suítes completas seguidas. |
| 15 | Teste `E2.4` (etapa 13.5) reescrito com condição dupla | Asseria só "último sucesso há < 300s" e falhava de forma **sistemática** com o banco ocioso: o `sync-worker` só registra ciclo de sucesso quando há linha nova, então sem escrita na origem o intervalo passa de 300s sozinho. Medido no momento da falha: **1516s de idade com lag de 0,98s** e o worker rodando ciclos normalmente. O teste asseria a condição errada desde a 13.5 — não é regressão da 15 nem defeito do worker. | Passou a exigir idade > 300s **E** lag > 60s, exatamente a expressão do alerta `PipelineParado` em `alert_rules.yml`. A mesma armadilha moldou o desenho do alerta: alertar só pela idade acordaria o plantão toda madrugada, e alerta silenciado não detecta o incidente para o qual existe. |
| 15 | 2 dos 6 alertas de E11 substituídos por equivalentes | E11 foi escrito quando o CDC estava no caminho principal. O alerta de **DLQ** monitorava a dead-letter queue do consumidor Debezium, e o de **slot de replicação** vigiava WAL represado por consumidor ausente — nenhum dos dois existe no desenho por micro-batch (ver `desafio-2/ADR.md`). | DLQ → `sync_errors_total` (mesmo papel: falha recorrente que alguém precisa olhar sem urgência). Slot → `up == 0` (o risco análogo é o alvo de métricas cair e **cegar todos os outros alertas**, inclusive o de pipeline parado). Os 6 alertas do PDF § 5.2 B.2 seguem entregues, com a substituição justificada em `desafio-3/grafana/alertas.md`. |
| 15 | `init/prometheus/` estava vazio — arquivos criados do zero | O `PASSO 3` da etapa dizia "subir o Prometheus com `init/prometheus/prometheus.yml`", pressupondo que o arquivo existisse. O serviço estava no compose desde a etapa 02 apontando o volume para o diretório, mas **sem nenhum arquivo dentro** — por isso reiniciava em loop desde então. Não era configuração a ajustar, era a ausência dela. | `prometheus.yml` (7 alvos: 3 workers Python, 2 pg-exporter, ClickHouse e self) e `alert_rules.yml` (6 regras) escritos. Prometheus estável, 7/7 alvos `up`, 6 regras `health=ok`. |
| 15 | ClickHouse ganhou endpoint Prometheus (`config.d/prometheus.xml`) | O dashboard de ClickHouse precisa de merges, partes por partição, memória e queries ativas. O ClickHouse já coleta tudo em `system.metrics`, mas não publica em formato Prometheus sem declaração explícita — e não há exporter externo para ele no compose, ao contrário dos dois PostgreSQL. | Arquivo montado em `config.d/`, **mesmo padrão já usado pelo `backup.xml`** — sem trocar imagem (Seção 2) nem mexer em schema. Container recriado com conferência de dado antes e depois: **10.000.000 linhas nas duas pontas**. |
| 15 | Dashboards movidos para fora de `provisioning/` | Com os `.json` no mesmo diretório do `dashboards.yml`, o Grafana tenta ler o próprio `.yml` como se fosse um dashboard e **não carrega nenhum** — o log registra "finished to provision dashboards" sem erro, e a UI fica vazia. Falha silenciosa: o provisionamento "passa" sem entregar nada. | `.json` em `init/grafana/dashboards/` (montado em `/var/lib/grafana/dashboards`), `provisioning/dashboards/` só com o `dashboards.yml`. Teste `15.15` guarda a regressão. Datasources também ganharam **UID fixo**, sem o qual o Grafana gera UID aleatório e os painéis quebram a cada recriação. |
| 15 | `StorageAlto` sem série ativa neste ambiente | Não há `node_exporter` no compose, então `node_filesystem_avail_bytes` não é coletada. A regra fica carregada, válida e nunca dispara. | Mantida a expressão que valeria em produção em vez de trocá-la por um proxy local (`df` via script) que não se pareceria com o alarme real do CloudWatch. É a única das 6 sem série neste ambiente, e está declarado em `desafio-3/grafana/alertas.md`. |
| 16 | Passo 6 (LGPD no ClickHouse) **inverteu a conclusão** do documento original | A etapa 09 descreveu a propagação do apagamento ao ClickHouse como procedimento a executar "quando o CH existir". Executado na 16, o resultado foi outro: **não há propagação a fazer**. `accounts_dim` — citada no procedimento original — nunca foi criada, e `transactions_raw` referencia o titular apenas por `source_account_id` (inteiro). Verificado por varredura de `system.columns` (zero colunas de PII) e por teste de ponta a ponta com conta sintética. | Passo reescrito como **verificação com evidência** em vez de procedimento pendente, com a tabela dos 7 passos executados. O procedimento hipotético (`OPTIMIZE FINAL` + `ALTER TABLE DELETE`) ficou registrado para o caso de uma dimensão com PII ser materializada no futuro. É consequência da decisão de schema de S01 — PII só em `accounts` —, não sorte. |
| 16 | Matriz da auditoria § FASE 3 **reescrita**, não apenas conferida | O `PASSO 7` pedia "conferir item a item". A conferência mostrou a matriz desatualizada em **21 linhas**: ela é o retrato do momento da auditoria, quando o CDC tinha acabado de ser descartado e as etapas 13.5–16 não existiam. Manter linhas em **FALTA** para requisitos entregues (backup, dashboards, ADR, diagramas, API, ref-sync, runbook, incidente) daria à banca a impressão de lacuna onde não há. | Cada linha reconferida **contra o ambiente rodando**, não contra o plano: 11 containers de pé, `--profile core`/`full` resolvendo, backup `20260804-140710F` válido, `demo-sync-worker.sh` reexecutado com sucesso. Critérios do PDF § 6.1 passaram de **2/7 para 7/7**. Nenhuma linha em FALTA; só C2b permanece PARCIAL, justificada. Teste `16.11` guarda a ausência de FALTA. |
| 16 | Teste `12.6` quebrou durante a etapa (MV × raw fora de sincronia) | O `ALTER TABLE ... DELETE` que removeu a transação sintética do teste LGPD da `transactions_raw` **não removeu o agregado correspondente nas 2 MVs**: MV no ClickHouse é gatilho de inserção, não view materializada que recalcula ao mudar a origem. Raw voltou a 10.000.000 e as MVs ficaram em 10.000.001. **Mesma classe de armadilha da etapa 12**, no sentido inverso (lá o `INSERT SELECT` duplicou o que a MV já tinha capturado). | Removida e reconstruída **apenas a fatia divergente** (`day='2026-08-04'`, `source_institution='001'`, `type='pix'`) nas 2 tabelas de agregação, a partir da raw, com `mutations_sync=2`. As 3 tabelas voltaram a 10.000.000 exatos. Registrado no `ESTADO HERDADO` da 99: **conferir `countMerge` das MVs ao validar, não só a raw**. |
| 17 | Comparação Aurora × RDS **inverteu de sinal** e mudou a justificativa da recomendação | O passo previa trocar o percentual por valor absoluto, assumindo que o absoluto confirmaria o "~20–30% acima do RDS" herdado da etapa 16. Não confirmou: **+$26/mês (+10%) no volume atual, −$170/mês (−17%) no cenário 10×**. O texto antigo era verdade por vCPU e falso como conta mensal — Serverless v2 escala para baixo em ocioso, RDS Multi-AZ provisiona para o pico 24/7. | Recomendação de Aurora **mantida**, justificativa reescrita: se paga por HA e reader endpoint, **não por preço no volume atual**. A ressalva do `migration-analysis.md` passou a dizer explicitamente que vender Aurora como economia hoje seria falso, e que a economia chega com o crescimento. |
| 17 | Âncora do gerenciado incluída **mesmo enfraquecendo a tese** do autogerido | O TCO precisa responder "quanto já se paga hoje", senão flutua. Timescale Cloud ($400–500) + ClickHouse Cloud ($350–600) somam ≈$750–1.100 contra os ≈$844 da arquitetura proposta — ou seja, **não há economia relevante em autogerir neste volume**. | Linha incluída na tabela com a conclusão escrita por extenso, em vez de omitida. Mesmo espírito do "índice que não melhorou" (etapa 07) e do empate do Dictionary em `GROUP BY` (etapa 16): o número desfavorável fica na mesma tabela do favorável. A decisão de autogerir só se paga a partir do cenário B, e isso está dito. |
| 17 | Baseline da suíte estava errado desde a etapa 16 (`171` → **174**) | O ESTADO HERDADO registrava `171 pass`, medição feita com parte dos testes de carga-real em SKIP. Com o ambiente inteiro de pé são **155 numerados + 34 do bloco E** (etapa 13.5), menos 3 SKIP de `make`. Não é regressão nem defeito — é número desatualizado propagado entre etapas. | Baseline corrigido para **186 pass / 0 fail / 3 skip** com o bloco 17 incluído. Registrado no `LOG-EXECUCAO.md` e no ESTADO HERDADO da 18 para não voltar a propagar. |
| 17 | `audit.sh` teste `A2.1` quebrou (esperava 18 arquivos de etapa, achou 23) | A asserção era fixa em 18 (15 originais + 99 + 13.5 + 16). As 5 etapas da revisão de entrega (17–21) a invalidaram. **Mesma classe de obsolescência** dos testes `04.6`/`06.3`/`06.4`/`11.6`/`02.2`/`06.2`: a asserção descrevia um ponto da esteira, e a esteira andou por decisão, não por defeito. | `A2.1` atualizado para 23, laço de conferência estendido a `17..21`, e o comentário do bloco registra que o número era 18 até a etapa 16 — para que a próxima pessoa saiba que ele muda quando a esteira cresce, em vez de tratar como regressão. `audit.sh`: **83 pass / 0 fail / 2 warn / 1 skip**. |
| 17.5 | Etapa **criada durante a execução da 18**, nascendo CONCLUÍDA — defeito em funcionalidade entregue | O PASSO 3 da etapa 18 (medir as queries-modelo contra o cluster real, em vez de copiar SQL) revelou que o `dict_institutions` resolvia só **33,55%** do volume: o seed do legado gerava `001`–`015` e o de transações usa códigos reais (`237`, `341`…). Só o `001` coincidia, e como ele é o topo da Zipf, a resolução parcial passava por dado bom. **A API já servia `"institution_name":"desconhecida"` para 66% das instituições.** O comentário do seed dizia que os códigos deveriam "casar 1:1", então era defeito, não decisão — o que se conferiu por 6 etapas foi a **cardinalidade** (15=15), nunca o valor. | Corrigido o seed do legado (direção barata: o seed de transações sustenta a Zipf, os outliers e todo o `REPORT.md`). `UPDATE` in-place porque as 2 FKs referenciam `id`, não `code` — 480 configs e 80.000 contas intactas. Resolução **33,55% → 100%**. `ref-sync` propagou sozinho pelo `invalidate_query`. Decisão confirmada com o usuário antes de executar (Seção 5). |
| 17.5 | Os 3 números de "Dictionary vs JOIN" do `REPORT.md` estavam **medidos sobre dado que não casava** | Um `dictGet` que devolve o *default* sai pelo caminho curto e não paga o custo real da resolução; a JOIN, que também não encontrava nada, parecia competitiva. Os **dois "empates honestos"** que a etapa 16 declarou eram artefato do defeito, não propriedade do Dictionary. | Os 3 padrões remedidos com resolução em 100%: lookup por linha **4 ms × 15 ms (3,75×)**, `GROUP BY` 10M **11 ms × 147 ms (13,4×)**, `GROUP BY` 90 d **18 ms × 72 ms (4,0×)**. A tabela antiga foi **substituída com explicação do porquê**, não apagada — o `REPORT.md` é onde a banca confere método, e sumir com medição errada é pior que o erro. O método da 16 (medir 3 padrões, publicar o desfavorável) continua certo e foi o que deixou a anomalia visível; faltou verificar o dado antes de medir. |
| 17.5 | Teste `14.4` **revertia a correção do dado silenciosamente** | Ele faz `UPDATE` em `partner_institutions`, confere a propagação ao Dictionary e restaura — mas restaurava o **literal** `'Instituição Parceira 1'`. O teste passava (a propagação de fato funciona) enquanto desfazia o conserto do `001` a cada execução da suíte. Só apareceu porque `14.19` (que grepava `"Institui"`) falhou logo depois. | Ambos passaram a **ler o valor do banco** em vez de assumir um literal: `14.4` guarda o nome atual antes do `UPDATE` e restaura o que leu; `14.19` compara com o nome que está em `partner_institutions`. Teste que restaura literal impõe o dado antigo — vale como regra para os testes de perfil da etapa 19. |
| 17.5 | Teste `16.9` quebrou (asseria o literal `"0,018"` no `REPORT.md`) | A asserção prendia o teste a um valor de medição específico, então qualquer remedição legítima o quebrava. Mesma classe de `04.6`/`06.3`/`06.4`/`11.6`/`02.2`/`A2.1`. | Reescrito para asserir a **propriedade** — existe tabela com os dois caminhos e unidade de tempo — em vez de um número. |
| 18 | Trade-off de `accounts`/Q2 **nunca havia sido declarado**, só a decisão de schema | O plano pedia declarar "no guia e no `REPORT.md`". Ao escrever, o `REPORT.md` não tinha nenhuma menção à **consequência**: PII fora do ClickHouse significa que Q2 (reconciliação com dados de conta) não é respondível no motor analítico. A decisão estava documentada desde S01; o custo dela, não. | Seção nova no `REPORT.md` (§ Limitação declarada: `accounts` não vai ao ClickHouse) com a tabela de caminhos alternativos, mais o § 6 do guia. Teste `18.12` guarda a presença nos dois. |
| 19 | Perfil criado por **RBAC via SQL**, não por `users.d/` — e isso eliminou o risco previsto no próprio ROLLBACK da etapa | O passo 2 previa arquivo em `init/clickhouse/users.d/`, o que exigiria **recriar o container** só para criar usuário, com 10M carregados no volume. Verificado que o compose já traz `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT: 1` e que `/var/lib/clickhouse/access/` persiste no volume. | Perfil, role, quota e usuário criados por SQL. Confirmado na prática que sobrevivem: `analytics_ro` seguiu de pé após o `up -d` que montou a named collection. Dado conferido antes e depois — 10.000.000 nas 3 pontas (teste `19.13`). |
| 19 | `CREATE QUOTA ... TO <settings profile>` não existe (`UNKNOWN_ROLE`) | Quota no ClickHouse se prende a **role ou usuário**, não a settings profile. Erro pego rodando, não lendo doc. | `TO analytics_reader` (a role). Estrutura final: profile com os limites → role que carrega o profile → quota na role → usuário com a role. |
| 19 | O Dictionary **vivo** não acompanhou o arquivo corrigido | Recriar o container **não** reaplica `init/` — ele só roda em volume novo. O `.sql` do repositório já estava sem a credencial enquanto o `SHOW CREATE DICTIONARY` ainda mostrava a senha inline. **O teste `19.6` passaria (o arquivo está limpo) com o servidor usando o segredo antigo** — falso positivo perigoso justamente no teste de segredo. | `DROP`/`CREATE` explícito do Dictionary para o schema versionado e o estado real coincidirem. Acrescentado o teste `19.11`, que confere a **resolução dos 10M** depois da troca, em vez de só a ausência da string no arquivo. |
| 19 | `pgaudit` indisponível na imagem fixada mudou o desenho da trilha | A extensão não consta de `pg_available_extensions` e trocar a imagem violaria a Seção 2 — mesma restrição do `percentile_agg` na etapa 08. | Trilha implementada com função `SECURITY DEFINER` (`read_accounts_audited`, com finalidade obrigatória e `rows_returned`) + gatilho append-only. **Limite declarado no § 4 e § 8 do documento**: cobre o caminho auditado; quem tiver `SELECT` direto em `accounts` (hoje o superusuário `trio`) lê sem rastro, e isso só fecha em produção com `REVOKE` + `pgaudit` no parameter group do Aurora. |
| 20.5 | Etapa criada durante a execução da 20 — **perda silenciosa de dados no pipeline entregue** | O teste de saturação (passo 3 da 20) escreveu 60.000 linhas num único `INSERT`: chegaram **50.000**, o worker parou de emitir ciclos, o lag congelou e **nenhum erro apareceu no log**. Causa-raiz com 3 fatos: `now()` é fixo por statement (as 60.000 têm o **mesmo** `updated_at`); o `LIMIT BATCH_MAX_ROWS` corta no meio desse instante; e o filtro `updated_at > limite` descartava o excedente a cada ciclo. **O comentário do próprio código previa o sintoma** ("se este número for sempre igual ao lote inteiro, o watermark travou") — o diagnóstico existia, a guarda não. Passou por 8 etapas porque todo teste anterior usava lote pequeno. | Watermark passou a ser o par `(updated_at, id)` no schema, na leitura, no filtro e no commit. Regressão: 60.000 num statement → **60.000 entregues**. Overlap e mutação reconferidos. Decisão de corrigir a causa (e não subir `BATCH_MAX_ROWS`) confirmada com o usuário. |
| 20.5 | **A primeira correção não funcionou** e travou o pipeline por outro caminho | Trocar predicado e filtro pela tupla não bastou: o `overlap` recua o timestamp, recuar obriga a começar do `id 0` daquele instante, e aí o `LIMIT` se esgotava nas 50.000 **já escritas** — o filtro descartava todas e o ciclo terminava sem escrever nada. | Retomada e overlap separados em **duas leituras**: retomada exata a partir de `(wm_ts, wm_id)` primeiro (é ela que garante progresso), overlap só quando a retomada não encheu o lote. Watermark virou `max()` do par, não `linhas[-1]` — com duas leituras o lote deixa de ser monotônico. **A versão intermediária foi construída, testada e reprovada antes de chegar nesta.** |
| 20 | O teste de saturação **não saturava**, e teria produzido conclusão falsa | Os 4 patamares planejados (500 → 5.800/s) passaram com zero perda e lag < 7 s. O script teria reportado "o pipeline aguenta o pico de 5.800/s do cenário 10×" — verdadeiro e enganoso: `INSERT` em massa escreve 5.800 linhas em 0,43 s, e nenhum patamar chegava perto de `BATCH_MAX_ROWS` (50.000). | Patamar de **60.000** acrescentado — o único acima do lote, e o que revelou o bug da 20.5. Coluna de **entrega por patamar** acrescentada: conferir só o total no fim mascara qual patamar perdeu linha. Resultado final: **zero perda em 70.300 linhas, lag máximo 19,2 s** contra alvo de 30 s. |
| 20 | A validação em clone limpo **achou um defeito no `audit.sh`** | Rodando de um clone, `A2.1` falhou: esperava 24 arquivos de etapa e achou 25 — a 20.5 foi criada sem atualizar o contador. Só aparece rodando de fora do diretório de trabalho, que é exatamente o argumento a favor do passo 7. | `A2.1` atualizado para 25, com `20.5` no laço de conferência. As outras 2 falhas no clone (`A1.9` exige containers de pé, `A7.6` compara o caminho do git root) são propriedades de rodar fora do lugar, não defeitos — registradas para não serem reinvestigadas. |
| 20 | Resposta da pergunta 3 do PDF citava `RENAME`, que **não** é atômico | `RENAME` em dois tempos (`raw`→`raw_old`, `raw_new`→`raw`) tem um instante em que a tabela `transactions_raw` não existe, e toda consulta nesse intervalo falha — o oposto de "sem downtime". | Procedimento reescrito com **`EXCHANGE TABLES`**, atômico, verificado disponível nesta versão (24.8). A resposta das 5 perguntas foi desenvolvida junto, saindo de 1 linha para procedimento com pré-requisito (Keeper antes do `CREATE`) e ponto de rollback. |
| — | Etapa **16** criada fora do plano original | A matriz de rastreabilidade da auditoria (§ FASE 3) lista requisitos do PDF marcados **PARCIAL** que nenhuma etapa do roadmap cobria: P95/P99 por instituição (A4b), retenção declarada (A5), análise Aurora com os 4 sub-itens (B3), limitação do funil de status (C2b) e o texto "Dictionary vs JOIN" (C3). Sem uma etapa dona, cairiam entre as cadeiras. | `16-fechamento-de-lacunas-do-pdf.md`, com critério de aceite explícito: nenhuma linha da matriz pode ficar em FALTA, e toda linha que permanecer PARCIAL precisa de justificativa escrita. |

## As 5 perguntas previstas (PDF § 7)

1. **"E se o volume triplicasse, o que mudaria na arquitetura?"**
   Quatro movimentos, **nessa ordem** (`ADR.md` § escala): (1) **particionar o
   sync-worker** por faixa de `source_institution`, com um watermark por
   partição — N workers sem coordenação entre si, escala linear, sem mudar
   schema; (2) **aumentar o lote antes da frequência** — o ClickHouse prefere
   poucos INSERTs grandes; encurtar o ciclo multiplica *parts* e força merges;
   (3) **deixar o peso nas MVs**, que agregam na ingestão, então o custo cresce
   com o que entra e não com o acumulado; (4) **só então fila (MSK)**.
   Sustenta tudo isso a idempotência: `ReplacingMergeTree(_version)`, testado
   reprocessando a mesma janela sem duplicar.
   **Números para defender:** teste de saturação em 5 patamares até 60.000
   linhas num statement, **zero perda**, lag máximo **19,2 s** contra alvo de
   30 s (`desafio-2/saturacao-resultado.md`). No cenário 10×, o custo sai de
   ≈$844 para ≈$2.677/mês, e o custo por milhão **cai de $84 para $27**.
   A fila é o último passo por preço também: **$620/mês, 73% do custo atual da
   plataforma inteira**.

2. **"Como adicionaria um novo consumer no ClickHouse sem impactar as aplicações existentes?"**
   Procedimento escrito em `desafio-2/PROCEDIMENTOS-PRODUCAO.md` § 1.
   Resumo: criar a tabela de destino → **anotar o instante de corte** → criar a
   MV (**nunca com `POPULATE`**) → backfill só do que é anterior ao corte →
   validar contra a raw → publicar.
   **O ponto que prova experiência:** existe um instante — o
   `CREATE MATERIALIZED VIEW` — que divide o dado entre "a MV pega sozinha" e
   "preciso de backfill". Errar isso foi o que **duplicou 10M** na etapa 12
   (`INSERT SELECT` sobre MV já ativa → 20.000.000 agregados). E o inverso
   aconteceu na 16: `DELETE` só na raw deixou a MV 1 linha à frente. Impacto no
   existente: nenhum na leitura, +1 gravação por lote na escrita, e rollback é
   `DROP VIEW` — a raw nunca é tocada.

3. **"Como faria a migração de engine de uma tabela ClickHouse em produção sem downtime?"**
   Procedimento em `desafio-2/PROCEDIMENTOS-PRODUCAO.md` § 2, com o caso real:
   `ReplacingMergeTree` → `ReplicatedReplacingMergeTree`.
   Tabela sombra com a engine de destino (`ORDER BY`/`PARTITION BY` **idênticos**
   — se mudarem, é reescrita de dado, não troca de engine) → dupla escrita por
   MV → backfill **por partição** → validação **por partição** (total igual pode
   esconder uma a mais e outra a menos; em `ReplacingMergeTree` conferir também
   `count() FINAL`) → **`EXCHANGE TABLES`** → 72 h de janela → `DROP`.
   **`EXCHANGE TABLES`, não `RENAME`:** o `RENAME` em dois tempos tem um
   instante em que a tabela **não existe** e toda consulta falha. `EXCHANGE` é
   atômico. Pré-requisito que quase se esquece: `Replicated*` exige **Keeper de
   pé antes** — o `CREATE` falha sem ele. E o RBAC é estado à parte, que vive em
   `/var/lib/clickhouse/access/` e precisa de `ON CLUSTER`.

4. **"Qual sua estratégia para onboardar um Data Champion novo?"**
   `docs/DATA-CHAMPIONS.md`, escrito para ser lido sem mim por perto.
   Como pedir acesso (perfil `analytics_ro`, que **existe** e nega o que deve
   negar) → catálogo das 2 MVs + raw + Dictionary, cada um com **o que responde
   e o que não responde** → 3 queries-modelo medidas (5 ms, 4 ms, 6 ms) e
   executadas pela suíte → regra MV vs raw → limites com a **mensagem de erro
   real** → Hex → escalonamento com dono e prazo.
   **A parte que economiza mais tempo é a das armadilhas**, todas encontradas
   executando: `-Merge` obrigatório, `countIfMerge` para coluna gravada com
   `countIf`, `tuple()` em chave `COMPLEX_KEY_HASHED`, `ILLEGAL_AGGREGATION` em
   agregação aninhada, e MV-como-gatilho. Cada uma com o erro literal, para
   achar por `Ctrl+F` quando a query quebra.
   **Controle de custo é servidor, não convenção:** `max_execution_time=60`,
   `max_rows_to_read=50M`, `max_memory_usage=4GiB` e quota horária amarrados ao
   perfil, com `readonly=1` — o usuário não afrouxa o próprio teto.
   E o trade-off declarado: reconciliação com dado de conta **não** é
   respondível no ClickHouse, porque PII não vai para lá.

5. **"Migrar o legado para Aurora amanhã — plano de 72h?"**
   `desafio-1/migration-analysis.md` (210 linhas, 4 sub-itens).
   h0-8 inventário · h8-16 Aurora provisionado, schema por `pg_dump
   --schema-only`, replicação lógica nativa (não DMS: origem e destino são
   PostgreSQL 16, o DMS existe para heterogeneidade) · h16-40 validação com
   contagem **e checksum** — contagem igual com soma diferente denuncia
   corrupção de tipo · h40-48 ensaio em espelho · h48-52 corte com lag zero ·
   h52-72 replicação reversa ativa.
   **O risco que mais derruba migração de PostgreSQL e quase ninguém cita:**
   `SERIAL` **não** dessincroniza sozinho — a replicação lógica copia linhas,
   não o estado das sequências. Sem `setval()` em cada uma antes de liberar
   escrita, a primeira inserção viola PK. Este projeto já esbarrou nessa classe
   de erro na etapa 10.
   **Critério de aborto decidido antes:** divergência de contagem ou checksum →
   aborta. Lag não zera em 15 min → aborta. Janela de rollback de 72 h com o
   legado **de pé e read-only**.
   E o número que a pergunta cobra: Aurora custa **+$26/mês (+10%)** que o RDS
   hoje e **−$170/mês (−17%)** no cenário 10× — a recomendação se paga por HA e
   reader endpoint, **não por preço no volume atual**.

> Duração da sessão: **30 a 45 minutos**, dito pelo PDF em § 2.1 e de novo em § 7. O `E13-Apresentacao.md` do vault já foi corrigido com o roteiro de 45 min e a ordem de corte para 30. O § 7 exige **4 blocos**: ambiente rodando, decisões arquiteturais, perguntas de aprofundamento e **discussão do cenário de incidente** — este último é fácil de esquecer no ensaio.

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 99.1 | carga-real | sequência `nuke`→`up`→`seed`→`indexes`→`policies`→`backfill`→`pipeline`→`check` | sai 0 ponta a ponta |
| 99.2 | carga-real | `bash scripts/tests/run_all.sh` | `0 fail` |
| 99.3 | local | `! grep '^| [1-7] |' scripts/roadmap/99-validacao-final.md \| grep -q 'PREENCHER'` | sai 0 (as 7 evidências preenchidas) |
| 99.4 | local | `! grep -q '<PREENCHER>' scripts/ambiente/DOCKER-LOCAL.md` | sai 0 |
| 99.5 | local | `test -f README.md -a -f desafio-1/REPORT.md` | sai 0 |
| 99.6 | compose | `make check` | sai 0 |

## ROLLBACK
```bash
git reset --hard <sha do checkpoint da etapa 15>
```

## STATUS
Estado: BLOQUEADA
Premissas assumidas: —
Desvios do plano: —

## FECHAMENTO
- [ ] Critérios atendidos
- [ ] Testes no run_all.sh
- [ ] run_all.sh sem FAIL
- [ ] ESTADO HERDADO da próxima preenchido
- [ ] Bloco no LOG-EXECUCAO.md
- [ ] Desvio? → atualizar 99-validacao-final.md
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
