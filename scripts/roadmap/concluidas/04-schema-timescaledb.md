# 04 — SCHEMA TIMESCALEDB  [compose]

## ORIGEM
`../vault-estudo/06-Especificacao/S01-DDL-TimescaleDB.md` § Tipos customizados · § Tabela `accounts` · § Tabela `transactions` — a hypertable · § Trigger de `updated_at` · § Tabela `reconciliation_events` · § Ordem de execução dos scripts · § Checklist de validação

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado ao fechar a etapa 03:
- `docker-compose.yml` (etapa 02) com os 15 serviços; parâmetros do TimescaleDB de S08 já aplicados em `command:` — conferir se batem com S01 § Parâmetros ajustados antes de reescrever.
- `Makefile` na raiz com 23 alvos (`help` default). Alvos que dependem de script/SQL inexistente falham com mensagem nomeando a etapa dona — `indexes` e `policies` continuam apontando para `init/timescaledb/03_indexes.sql`/`04_caggs_policies.sql`, que esta etapa (04) **não** cria.
- `scripts/wait-healthy.sh` e `scripts/health-check.sh` executáveis, testados com o core de pé (timescaledb/postgres-legado/clickhouse healthy).
- `init/timescaledb/00_init.sql` só tem `CREATE EXTENSION timescaledb CASCADE` + `pg_stat_statements` — nenhuma tabela ainda. Roda antes de qualquer arquivo novo em `init/timescaledb/` (ordem alfabética do entrypoint do Postgres).
- Ambiente Windows sem `make` no PATH (winget falhou por rede/Sourceforge) — `make help`/`make -n up`/`make check` foram validados via container Docker auxiliar (`docker:27-cli` com `make`+`docker-compose` instalados, `COMPOSE_PROJECT_NAME=trio-data-challenge`, socket montado). `run_all.sh` faz `SKIP` em 03.1/03.2/03.5 quando `make` está ausente — se a etapa 04 quiser usar `make` diretamente, aplicar o mesmo workaround ou instalar `make` manualmente antes.
- `.env` local presente (a partir de `.env.example`), não versionado.
- `run_all.sh`: blocos 01/02/03, 16 pass / 0 fail / 4 skip (2 do core sem containers de pé, 2 de make ausente).
- `audit.sh` segue com FAIL conhecido em A2.1/A2.01/A2.02 (script não conta `scripts/roadmap/concluidas/`) — defeito do próprio script de auditoria do plano, não do produto; documentado em STATUS da etapa 02 e 03, não bloqueia.

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
- [x] `timescaledb_information.hypertables` lista `transactions` e `reconciliation_events`
- [x] Chunk interval: 1 dia em `transactions`, 7 dias em `reconciliation_events`
- [x] Os ENUMs de S01 existem (`SELECT typname FROM pg_type WHERE typtype='e'`)
- [x] `accounts` **não** é hypertable e concentra toda a PII
- [x] A coluna gerada `difference` devolve `-0.05` no teste de S01 (esperado 100.00 − 99.95)
- [x] Trigger de `updated_at` dispara em `UPDATE`
- [x] `seed_control` existe e rejeita uma segunda linha
- [x] Nenhum índice além dos implícitos de PK/unique; nenhuma política criada

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
Estado: CONCLUÍDA
Premissas assumidas:
- Volume `timescaledb_data` precisou ser recriado (removido e recriado 2x) porque `init/` só roda na criação do container — necessário para aplicar o schema novo e depois corrigir `seed_control`. Sem dado real perdido (nenhum seed rodou antes desta etapa).
- `archive_command=pgbackrest ...` (S08) gera erro no log a cada tentativa de archive porque `pgbackrest` não está instalado na imagem `timescale/timescaledb`. Não afeta escrita/leitura; resolve-se de fato na etapa 15 (backup). Registrado em ESTADO HERDADO da 05 para não ser confundido com bug do schema.
Desvios do plano: `02_seed_marker.sql` teve uma primeira versão com colunas inventadas (`completed_at`/`row_count`) em vez das literais de S02 (`started_at`/`finished_at`/`total_rows`, constraint `single_row`). Detectado ao ler a ORIGEM da etapa 05 antes de fechar esta — corrigido para bater com S02 § Idempotência do seed antes do checkpoint. Nenhum artefato committed com a versão errada.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh
- [x] run_all.sh sem FAIL
- [x] ESTADO HERDADO da próxima preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → atualizar 99-validacao-final.md (n/a — corrigido antes do commit, sem impacto em arquitetura/PDF entregue)
- [x] Commit checkpoint
- [x] Mover pra concluidas/. Marcar [x] no CLAUDE.md
