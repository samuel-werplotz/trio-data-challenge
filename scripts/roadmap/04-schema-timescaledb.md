# 04 — SCHEMA TIMESCALEDB  [compose]

## ORIGEM
`../vault-estudo/06-Especificacao/S01-DDL-TimescaleDB.md` § Tipos customizados · § Tabela `accounts` · § Tabela `transactions` — a hypertable · § Trigger de `updated_at` · § Tabela `reconciliation_events` · § Ordem de execução dos scripts · § Checklist de validação

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
<preenchido pela etapa 03 ao fechar>

## ESCOPO
Faz: `init/timescaledb/01_schema.sql` (ENUMs, `accounts`, `transactions` + hypertable de 1 dia, `reconciliation_events` + hypertable de 7 dias, trigger de `updated_at`) e `init/timescaledb/02_seed_marker.sql` (`seed_control`). Destino final do DDL principal também em `desafio-1/schemas/01_timescale_schema.sql`, conforme o `arquivo_destino` de S01.
Não faz: **nenhum índice** e **nenhuma política** — `03_indexes.sql` é a etapa 07 e `04_caggs_policies.sql` é a 08. Criar índice agora apagaria o "antes" que a etapa 06 precisa medir. Não carrega dado.

## PASSOS
1. Escrever os ENUMs de S01 § Tipos customizados, literalmente.
2. Escrever `accounts` conforme S01 § Tabela `accounts` — tabela comum, **não** hypertable: é onde mora toda a PII e por isso nunca é comprimida.
3. Escrever `transactions` + `create_hypertable(..., by_range('created_at', INTERVAL '1 day'))`. Sem FK, por decisão de S01 — comentar o porquê no arquivo.
4. Escrever o trigger de `updated_at` de S01 § Trigger de `updated_at` (é ele que alimenta o `_version` do ClickHouse e o watermark do plano B).
5. Escrever `reconciliation_events` + hypertable com chunk de 7 dias, incluindo a coluna gerada `difference`.
6. Escrever `02_seed_marker.sql` com `seed_control` (`id` fixo em 1, `CHECK (id = 1)`).
7. Aplicar os parâmetros de S01 § Parâmetros ajustados no compose, se a etapa 02 não os tiver aplicado; se já estiverem, apenas conferir.
8. Rodar o checklist de S01 § Checklist de validação e acrescentar o bloco `# --- 04 schema-timescaledb ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] `timescaledb_information.hypertables` lista `transactions` e `reconciliation_events`
- [ ] Chunk interval: 1 dia em `transactions`, 7 dias em `reconciliation_events`
- [ ] Os ENUMs de S01 existem (`SELECT typname FROM pg_type WHERE typtype='e'`)
- [ ] `accounts` **não** é hypertable e concentra toda a PII
- [ ] A coluna gerada `difference` devolve `-0.05` no teste de S01 (esperado 100.00 − 99.95)
- [ ] Trigger de `updated_at` dispara em `UPDATE`
- [ ] `seed_control` existe e rejeita uma segunda linha
- [ ] Nenhum índice além dos implícitos de PK/unique; nenhuma política criada

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 04.1 | compose | `psql -c "SELECT count(*) FROM timescaledb_information.hypertables"` | 2 |
| 04.2 | compose | `psql -c "SELECT count(*) FROM pg_type WHERE typtype='e'"` | conforme S01 |
| 04.3 | compose | insert de teste de S01 + `SELECT difference` | `-0.05` |
| 04.4 | compose | `UPDATE transactions SET status=status WHERE id=<x>` e conferir `updated_at` | valor mudou |
| 04.5 | compose | `INSERT INTO seed_control(id) VALUES (2)` | falha por CHECK |
| 04.6 | compose | `psql -c "SELECT count(*) FROM pg_indexes WHERE tablename='transactions'"` | só o implícito de PK |

## ROLLBACK
```bash
docker compose exec -T timescaledb psql -U trio -d trio -c "
DROP TABLE IF EXISTS reconciliation_events CASCADE;
DROP TABLE IF EXISTS transactions CASCADE;
DROP TABLE IF EXISTS accounts CASCADE;
DROP TABLE IF EXISTS seed_control CASCADE;
DROP TYPE IF EXISTS transaction_type, transaction_status, event_type CASCADE;"
git checkout -- init/timescaledb/ desafio-1/schemas/
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
