# 11 — SCHEMA CLICKHOUSE  [compose]

## ORIGEM
`../vault-estudo/06-Especificacao/S04-Schema-ClickHouse.md` § Tabela principal · § As decisões, coluna a coluna · § ORDER BY — justificativa resumida · § MV 1 — Resumo diário por instituição e tipo · § Padrão tabela + MV separadas · § MV 2 — Funil de status · § Dictionary · § Uso e o argumento contra JOIN

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado ao fechar a etapa 10:
- `postgres-legado`: schema aplicado (`init/postgres-legado/01_legacy_schema.sql` + `02_legacy_seed.sql`), 15 `partner_institutions`, 480 `institution_configs` (60 vigentes: 15 inst × 4 chaves com `effective_until IS NULL`), 50.000 `legacy_users`, 80.000 `legacy_accounts`. **Esta é a origem real do `dict_institutions` desta etapa** — `partner_institutions.code`/`name`/`is_active` mapeiam 1:1 para as 15 `source_institution` de `transactions` no TimescaleDB.
- `legacy_accounts` tem bloat induzido de propósito (83,3% dead, ~6× o espaço útil) — irrelevante para o Dictionary (que lê de `partner_institutions`/`institution_configs`, não de `legacy_accounts`), mas não foi limpo (`VACUUM` não rodou) e persiste como estava ao fechar a 10.
- 2 queries complexas do legado medidas (`legacy_q1`/`legacy_q2`, antes/depois de `ANALYZE`); `desafio-1/migration-analysis.md` escrito, nenhum recurso AWS provisionado.
- **`postgres-legado` está healthy, mas `clickhouse` ainda não subiu nesta sessão** — o perfil ativo até agora foi `core` sem incluir o serviço `clickhouse`. Esta etapa precisa subi-lo (`docker compose up -d clickhouse` ou perfil que o inclua) antes de aplicar `01_schema.sql`.
- `timescaledb`: estado inalterado desde a etapa 09 — 10.000.000 `transactions`, 2 CAggs, compressão e retenção ativas. Nenhuma etapa entre 09 e 10 tocou o TimescaleDB.
- `run_all.sh`: blocos 01–10, **67 pass / 0 fail / 4 skip**. `audit.sh`: 83 pass / 0 fail / 1 warn / 1 skip. Dois desvios registrados em `99-validacao-final.md`: teste `06.2` restrito a `q[1-4]_before.txt` (colisão de glob com `legacy_qN_before.txt`); Legacy Q1 sem ganho de tempo pós-`ANALYZE` (ganho foi na estimativa de linhas, 509.298→80.000).

## ESCOPO
Faz: `init/clickhouse/01_schema.sql` — `transactions_raw` (`ReplacingMergeTree(_version)`), 2 tabelas `AggregatingMergeTree` + 2 MVs separadas, e o `dict_institutions`.
Não faz: **nenhum backfill** — as MVs ficam vazias de propósito; carregar dado é a etapa 12. Não usa `POPULATE` em MV nenhuma. Não registra o conector Debezium (etapa 13): a ordem obrigatória é schema → backfill raw → backfill MVs → conector.

## PASSOS
1. Criar `transactions_raw` com `ENGINE = ReplacingMergeTree(_version)`, `PARTITION BY toYYYYMM(created_at)`, `ORDER BY (type, source_institution, toStartOfHour(created_at), external_id)`.
2. Comentar no SQL, na linha do `ORDER BY`, **por que `status` está fora**: é coluna mutável, e incluí-la na chave de ordenação quebraria a dedup do `ReplacingMergeTree`. É a pergunta que a banca faz.
3. Comentar que `_version` = `updated_at` em milissegundos — é o que resolve o "qual linha vence" na dedup.
4. Aplicar os codecs por coluna de S04 § As decisões, coluna a coluna.
5. Criar as 2 tabelas `AggregatingMergeTree` (resumo diário por instituição e tipo; funil de status) e, **separadamente**, as 2 MVs que escrevem nelas. Nunca `POPULATE` — comentar que o backfill vem por `INSERT SELECT` na etapa 12.
6. Criar `dict_institutions` com `SOURCE(POSTGRESQL(...))`, `invalidate_query` e `LIFETIME(MIN 240 MAX 360)`; documentar o argumento contra `JOIN` e o uso via `dictGetOrDefault`.
7. Registrar no doc a limitação assumida: o funil de status mede **estado**, não transição — a origem não guarda histórico de mudanças.
8. Acrescentar o bloco `# --- 11 schema-clickhouse ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] `transactions_raw` existe com engine, `PARTITION BY` e `ORDER BY` exatamente como S04
- [x] `status` **não** aparece no `ORDER BY`, e o motivo está comentado no SQL
- [x] 2 tabelas `AggregatingMergeTree` + 2 MVs separadas existem
- [x] Nenhuma MV foi criada com `POPULATE`
- [x] `dict_institutions` carrega e responde a `dictGetOrDefault` (testado: código real do legado, não fallback)
- [x] As MVs estão **vazias** (backfill é a etapa 12) — `transactions_raw` com 0 linhas
- [x] Limitação do funil de status documentada (comentário no DDL, `01_schema.sql`)

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 11.1 | compose | `clickhouse-client -q "SHOW CREATE TABLE transactions_raw"` | `ReplacingMergeTree(_version)` |
| 11.2 | compose | `clickhouse-client -q "SHOW CREATE TABLE transactions_raw" \| grep -c 'ORDER BY.*status'` | `0` |
| 11.3 | compose | `clickhouse-client -q "SELECT count(*) FROM system.tables WHERE engine='MaterializedView'"` | `2` |
| 11.4 | local | `! grep -qi 'POPULATE' init/clickhouse/01_schema.sql` | sai 0 |
| 11.5 | compose | `clickhouse-client -q "SELECT dictGetOrDefault('dict_institutions','name',toUInt64(1),'?')"` | valor do legado |
| 11.6 | compose | `clickhouse-client -q "SELECT count(*) FROM transactions_raw"` | `0` (ainda sem backfill) |

## ROLLBACK
```bash
docker compose exec -T clickhouse clickhouse-client -q "
DROP DICTIONARY IF EXISTS dict_institutions;
DROP TABLE IF EXISTS mv_daily_summary;
DROP TABLE IF EXISTS mv_status_funnel;
DROP TABLE IF EXISTS daily_summary;
DROP TABLE IF EXISTS status_funnel;
DROP TABLE IF EXISTS transactions_raw;"
git checkout -- init/clickhouse/01_schema.sql
```

## STATUS
Estado: CONCLUÍDA
Premissas assumidas:
- `clickhouse` subido fora do fluxo de `--profile core` (que está quebrado por bug pré-existente do compose, alheio a esta etapa) — subido por nome de serviço direto.
- 4 colunas de estado agregado (`avg_settle_seconds`, `avg_seconds`, `p50_seconds`, `p95_seconds`) redeclaradas como `AggregateFunction(_, Nullable(Float32))` em vez de `Float32` puro — o DDL literal de S04 não compilava contra o tipo real produzido pelas MVs.

Desvios do plano: 2, ambos em `99-validacao-final.md` — tipo `Nullable` nas 4 colunas de estado agregado; bug de `profiles`/`depends_on` do compose (`grafana`→`prometheus`), contornado sem editar o compose.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (11.1–11.6)
- [x] run_all.sh sem FAIL — 74 pass / 0 fail / 3 skip
- [x] ESTADO HERDADO da próxima preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → atualizado 99-validacao-final.md
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
