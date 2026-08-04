# Trio Data Challenge — orquestrador

## 1. Operação
- Próxima etapa = menor `NN` em `scripts/roadmap/` que **não** esteja em `scripts/roadmap/concluidas/`.
- Ler **só** esse `.md` + este arquivo. Executar os `PASSOS`. Fechar pelo checklist da Seção 9.
- Etapa `BLOQUEADA` não se executa: resolver o `IMPEDITIVOS` primeiro ou pular para a próxima liberada.

## 2. Escopo travado (não reabrir)
| Fora do escopo | Motivo |
|---|---|
| Provisionar AWS real | Docker local é o único ambiente; AWS é documento escrito, nunca executado |
| `git push`, remote, PR | Sem remote. Commits locais em `wip/trio-challenge` |
| Copiar `../vault-estudo/` ou o PDF pra dentro do repo | Material de estudo, não entregável |
| Airflow / Dagster / orquestrador pesado | Decidido contra em `05-Decisoes/D06-Por-que-nao-Airflow.md` |
| CDC no PostgreSQL legado | Batch de 5 min é a decisão (`D05-Batch-vs-CDC-no-legado.md`) |
| Funil de status com histórico de transições real | Limitação assumida, documentada em S04 |
| Índice único global em `external_id` | Limitação assumida, documentada em S01 |
| Chave estrangeira em `transactions` | Deliberado, documentado em S01 |
| Trocar imagens/versões fixadas em S08 | Reprodutibilidade é requisito |

## 3. Arquitetura travada
Fonte de verdade: `../vault-estudo/06-Especificacao/`. S01–S08 + S09 (`S05-LGPD-Sanitizacao.md`) são **contrato**: DDL, engines, `ORDER BY`, codecs, distribuições, parâmetros e alvos de Makefile saem de lá literalmente.
- **O PDF do desafio é canônico** — o vault explica, o PDF avalia; divergiu, o PDF vence. `S10-Conformidade-PDF.md` rastreia cada requisito numerado até onde é atendido; consultar ao fechar etapa que entrega requisito do PDF.
- **TimescaleDB**: `transactions` hypertable `by_range('created_at', INTERVAL '1 day')`; `reconciliation_events` chunk 7d; `accounts` tabela comum. **PII só em `accounts`** — nunca comprimida; `transactions` e CAggs livres de PII por design. LGPD = tabela lateral (opção C de S09).
- **CAggs**: `cagg_volume_hourly` (1h, group by type+status); `cagg_settlement_latency_daily` (1d, `percentile_agg`). Ambos `WITH NO DATA` + materialização em lotes trimestrais.
- **Compressão**: `segmentby='source_institution, type'`, `orderby='created_at DESC, status'`, política 7d.
- **Retenção**: criada e **desabilitada** (`alter_job(..., scheduled => false)`) — conflito 90d × dataset de 12 meses.
- **ClickHouse**: `transactions_raw` = `ReplacingMergeTree(_version)`, `PARTITION BY toYYYYMM(created_at)`, `ORDER BY (type, source_institution, toStartOfHour(created_at), external_id)`. `status` **fora** do ORDER BY: é mutável e quebraria a dedup. `_version` = `updated_at` em ms.
- **MVs**: tabela `AggregatingMergeTree` + MV separada, nunca `POPULATE`; backfill `INSERT SELECT` obrigatório. **Dictionary**: `dict_institutions` via `SOURCE(POSTGRESQL(...))` + `invalidate_query`, `LIFETIME(MIN 240 MAX 360)`, lido com `dictGetOrDefault`.
- **Pipeline**: Debezium (`pgoutput`) → Redpanda → consumidor Python → ClickHouse. Publication manual com `publish_via_partition_root = true`; RegexRouter como rede de segurança; `snapshot.mode: no_data`. Backfill dos 10M é **direto PG→ClickHouse**, não pelo Kafka.
- **Plano B do CDC**: micro-batch por watermark `updated_at`; gatilho = 2h sem sucesso; reaproveita `sink.py`/`metrics.py`; perde `DELETE` (documentado).
- **Ordem obrigatória do pipeline**: schema CH → backfill raw → backfill MVs → **só então** registrar o conector.
- **Ref-sync**: batch 5 min, legado → Dictionary. Nunca CDC. **Backup**: pgBackRest → MinIO (`repo1-type=s3`), MinIO externo na **9002** (9000 é do ClickHouse); ClickHouse via `clickhouse-backup`.
- **Ordem de implementação**: S08 → S01 → S02 → **S06 (queries) → S03 (CAggs)**. A inversão é deliberada: medir as queries **sem** CAgg produz o "antes" honesto. Não reordenar.
- **Medição** (ritual de S06, não negociável): versão ingênua → `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` em `qN_before.txt` → otimizar → `EXPLAIN` de novo em `qN_after.txt` → descartar a 1ª execução, **registrar mediana de 3**, sempre reportando `Buffers: shared hit vs read`. Índice que não melhorou entra na tabela do `REPORT.md` do mesmo jeito.

## 4. Regra de contexto
- Sem `@import` — import carrega no boot e anula a economia. Caminhos sempre em texto puro.
- Ler só a etapa atual. Não abrir `concluidas/`, não abrir etapa futura, não reler etapa fechada.
- Abrir S-doc só quando a etapa mandar, e só a seção citada em `ORIGEM`.

## 5. Política de impedimento
**Trava e espera** (não decide sozinho): divergir de qualquer linha de S01–S08/S09 · mudar engine, `ORDER BY`, `PARTITION BY`, chunk interval, codec ou schema · mudar contrato do conector Debezium ou formato do evento · acionar o plano B do CDC · `docker compose down -v`, `DROP`, `TRUNCATE`, apagar volume ou qualquer perda de dado carregado · qualquer coisa que toque AWS real · `git push`, criar remote, mexer em branch principal · violar fronteira da Seção 2.

**Segue, registra premissa em `## STATUS`, continua**: nome de arquivo/função/variável e organização interna de módulo · escolha entre libs equivalentes · formato de log e de saída de script · ordem de passos dentro da mesma etapa · ajuste de redação em documento.

## 6. Regra de comentário de código
O repositório vai ser lido por uma banca. Comentário não é opcional nem decorativo.
- Todo arquivo novo recebe cabeçalho de 1–3 linhas: o que faz e onde encaixa no fluxo.
- Toda função/bloco não trivial recebe comentário de **intenção** — por que existe, não narração linha a linha.
- Nada de comentário redundante (`-- incrementa i`) nem bloco decorativo grande.
- Nome claro substitui comentário sempre que possível; comentário só onde o nome não basta.
- Vale para SQL, Python, YAML e scripts de teste — não só na etapa final.
- **Extra deste projeto**: onde o vault registra um trade-off (por que `status` está fora do `ORDER BY`, por que `end_offset` existe, por que índice parcial), o código carrega uma linha apontando o porquê. É o que a banca vai perguntar.

## 7. Regra de teste
- Dois scripts, propósitos distintos: `scripts/tests/audit.sh` audita o **plano** (roadmap, regras, rastreio do PDF) e é fixo — rodar antes da 01 e ao fechar etapa que mexeu em `.md` de roadmap; `run_all.sh` testa o **produto** e cresce a cada etapa.
- `scripts/tests/run_all.sh` é **cumulativo**: cada etapa acrescenta um bloco, nunca substitui os anteriores.
- `SKIP` no que a máquina não suporta ou cuja pré-condição não existe; `SKIP` não é falha. Nenhum `FAIL` antes de fechar etapa.
- Teste automático não substitui revisão humana — é guarda de regressão.

## 8. Regra de git
- Branch de trabalho: `wip/trio-challenge` (criada na etapa 01, junto do `git init`).
- Commit ao fechar cada etapa: `checkpoint: NN — <nome da etapa>`.
- **Nunca** `push`, `merge`, criar remote, ou trabalhar em `main`/`master` sem instrução explícita.
- Mudança destrutiva (migration, alteração de schema) só com o comando reverso escrito no `## ROLLBACK` da etapa.
- Nunca commitar segredo. `.env` no `.gitignore`; `.env.example` versionado.
- `.gitignore` cobre: `.env`, `__pycache__/`, `*.pyc`, `.venv/`, dumps de backup, `queries/explains/*.raw`.

## 9. Checklist de fechamento
Critérios atendidos → testes no `run_all.sh` → `run_all.sh` sem FAIL → `ESTADO HERDADO` da próxima etapa preenchido com **o que de fato existe** → bloco no `LOG-EXECUCAO.md` → houve desvio? atualizar `99-validacao-final.md` → commit `checkpoint: NN — <nome>` → mover pra `concluidas/` e marcar `[x]` na Seção 10.

## 10. Esteira
`B` = nasce BLOQUEADA (trilha `carga-real`). Marcar `[x]` ao fechar.
- [x] 01 baseline-e-estrutura · local
- [x] 02 compose-evoluido · compose
- [x] 03 makefile-e-healthcheck · compose
- [x] 04 schema-timescaledb · compose
- [x] 05 seed-10m · B
- [x] 06 queries-antes-indices · B
- [ ] 07 indices-e-otimizacao · B
- [ ] 08 caggs-compressao-retencao · B
- [ ] 09 lgpd-sanitizacao · local
- [ ] 10 legado-e-migracao-aurora · compose
- [ ] 11 schema-clickhouse · compose
- [ ] 12 backfill-e-query-subsegundo · B
- [ ] 13 pipeline-cdc · B
- [ ] 14 ref-sync-api-e-adr · compose
- [ ] 15 backup-observabilidade-e-incidente · compose
- [ ] 99 validacao-final · B

## 11. Ficha de ambiente
- Ficha: `scripts/ambiente/DOCKER-LOCAL.md`.
- Enquanto houver `<PREENCHER>` na ficha, **toda etapa de trilha `carga-real` permanece `BLOQUEADA`**.

## 12. Estilo de resposta
- Direto. Sem preâmbulo, sem prosa de transição, sem repetir o que foi pedido.
- Bullet e tabela por padrão; parágrafo só quando bullet perde informação.
- Zero elogio ao próprio plano. Pergunta só quando bloqueia.
- Status ao fim de cada etapa: **uma linha**. Comentários, docs e commits em PT-BR.
