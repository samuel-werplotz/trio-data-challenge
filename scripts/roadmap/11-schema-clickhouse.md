# 11 — SCHEMA CLICKHOUSE  [compose]

## ORIGEM
`../vault-estudo/06-Especificacao/S04-Schema-ClickHouse.md` § Tabela principal · § As decisões, coluna a coluna · § ORDER BY — justificativa resumida · § MV 1 — Resumo diário por instituição e tipo · § Padrão tabela + MV separadas · § MV 2 — Funil de status · § Dictionary · § Uso e o argumento contra JOIN

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
<preenchido pela etapa 10 ao fechar>

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
- [ ] `transactions_raw` existe com engine, `PARTITION BY` e `ORDER BY` exatamente como S04
- [ ] `status` **não** aparece no `ORDER BY`, e o motivo está comentado no SQL
- [ ] 2 tabelas `AggregatingMergeTree` + 2 MVs separadas existem
- [ ] Nenhuma MV foi criada com `POPULATE`
- [ ] `dict_institutions` carrega e responde a `dictGetOrDefault`
- [ ] As MVs estão **vazias** (backfill é a etapa 12)
- [ ] Limitação do funil de status documentada

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
Estado: PENDENTE
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
