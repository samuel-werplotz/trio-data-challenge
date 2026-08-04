# 05 — SEED 10M  [carga-real]

## ORIGEM
`../vault-estudo/06-Especificacao/S02-Gerador-de-Dados.md` § Parâmetros · § As distribuições · § A arquitetura do gerador · § Por que dividir por faixa de tempo, e não por linha · § COPY BINARY — o formato · § Ordem de execução · § Observabilidade do próprio seed · § Idempotência do seed · § Validação

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído

## ESTADO HERDADO
Verificado ao fechar a etapa 04:
- `init/timescaledb/01_schema.sql` com os 5 ENUMs, `accounts`, `transactions` (hypertable 1 dia) + trigger `set_updated_at`, `reconciliation_events` (hypertable 7 dias) com `difference` gerada. Cópia idêntica em `desafio-1/schemas/01_timescale_schema.sql` (destino canônico de S01).
- `init/timescaledb/02_seed_marker.sql` com `seed_control (id, started_at, finished_at, total_rows)`, `CHECK single_row (id=1)` — literal de S02 § Idempotência do seed. (Nota: a primeira versão desta etapa usou colunas inventadas `completed_at`/`row_count`; corrigido antes do checkpoint, pois S02 é a origem canônica desta tabela.)
- Nenhum índice além dos implícitos de PK (`transactions`: `transactions_pkey` + `transactions_created_at_idx` da hypertable; `accounts`: pkey + unique; `reconciliation_events`: só pkey). Nenhuma política, nenhum CAgg.
- Validado com container real: 2 hypertables, chunk 1d/7d confirmados via `timescaledb_information.dimensions`, trigger `updated_at` dispara em UPDATE (não em INSERT/COPY), `difference` retorna `-0.05` no caso de teste de S01, `seed_control` rejeita segunda linha.
- Volume `trio-data-challenge_timescaledb_data` existe com o schema aplicado, mas **vazio** (dados de teste da validação foram truncados) — não usar como se já tivesse dado; a etapa 05 começa de tabelas vazias.
- Parâmetros do TimescaleDB (S01 § Parâmetros ajustados) já batem no `docker-compose.yml` desde a etapa 02: `shared_buffers=1GB`, `effective_cache_size=3GB`, `maintenance_work_mem=1GB`, `max_wal_size=4GB`, `work_mem=16MB` mantido.
- `archive_command=pgbackrest --stanza=timescale archive-push %p` gera `FATAL: archive command failed with exit code 127` nos logs continuamente — `pgbackrest` não está instalado na imagem `timescale/timescaledb`. Não impede escrita/leitura (WAL archiving é assíncrono), mas polui `docker compose logs`. Configuração de S08, resolvida de fato só na etapa 15 (backup); registrar se afetar o gerador de dados.
- `run_all.sh`: blocos 01-04, 22 pass / 0 fail / 4 skip. `audit.sh` segue com FAIL conhecido (A2.1/A2.01/A2.02/A2.03 — não conta `concluidas/`), documentado desde a etapa 02, não bloqueia.
- `make` ainda ausente no PATH deste Windows; usar o workaround de container Docker auxiliar (etapa 03 STATUS) se `make seed` precisar rodar via `make` real, ou instalar antes.

## ESCOPO
Faz: `desafio-1/seed/generate_transactions.py` — gerador paralelo de 6 workers por faixa de tempo, `COPY BINARY` em lotes de 50k, idempotente via `seed_control`, com `ANALYZE` ao final. Carrega 500k contas, 10M transações e ~1,5M eventos de reconciliação.
Não faz: não cria índice nem CAgg (etapas 07 e 08); não toca ClickHouse; não divide trabalho por linha — a divisão é por faixa de tempo, e o porquê vai comentado no código.

## PASSOS
1. Implementar os parâmetros de S02 § Parâmetros literalmente: `TOTAL_TRANSACTIONS=10_000_000`, `MONTHS=12`, `N_ACCOUNTS=500_000`, `N_INSTITUTIONS=15`, `BATCH_SIZE=50_000`, `N_WORKERS=6`, `RECONCILIATION_PCT=0.15`.
2. Implementar as distribuições de S02 § As distribuições: por tipo, por hora do dia, por dia (pico em dia útil), por instituição via Zipf (`peso_i = 1/(i+1)^1.1`), por status, e a latência de liquidação.
3. Implementar o paralelismo: cada worker recebe um intervalo **contínuo** de datas (mantém poucos chunks quentes). Comentar no código que dividir por linha custaria >2h em vez de ~20 min.
4. Implementar `COPY BINARY` conforme S02 § COPY BINARY — o formato, em lotes de 50k.
5. Implementar a idempotência: consultar `seed_control`; se `finished_at` não é nulo, avisar e sair sem fazer nada. `seed-force` limpa antes.
6. Respeitar a ordem de S02 § Ordem de execução: `accounts` → `transactions` → `reconciliation` → **`ANALYZE`**. O `ANALYZE` não é opcional: sem ele os `EXPLAIN` da etapa 06 medem plano ruim por motivo errado.
7. Rodar o seed completo, cronometrar, e preencher `Seed de 10M concluído` e `Tempo real do seed` na ficha de ambiente.
8. Rodar a validação de S02 § Validação e acrescentar o bloco `# --- 05 seed-10m ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] `SELECT count(*) FROM transactions` = 10.000.000
- [ ] `SELECT count(*) FROM accounts` = 500.000
- [ ] `reconciliation_events` ≈ 1,5M (15% ± tolerância de S02)
- [ ] ~365 chunks em `transactions` (`timescaledb_information.chunks`)
- [ ] Distribuição por tipo, por status e por instituição dentro da tolerância de S02
- [ ] Volume por dia útil maior que fim de semana
- [ ] Percentis de latência por tipo coerentes com S02
- [ ] Rodar `make seed` uma segunda vez não insere nada (idempotência)
- [ ] `ANALYZE` executado ao final
- [ ] Ficha de ambiente sem `<PREENCHER>` nos campos de seed

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 05.1 | carga-real | `psql -c "SELECT count(*) FROM transactions"` | `10000000` |
| 05.2 | carga-real | `psql -c "SELECT count(*) FROM accounts"` | `500000` |
| 05.3 | carga-real | `psql -c "SELECT count(*) FROM timescaledb_information.chunks WHERE hypertable_name='transactions'"` | ~365 |
| 05.4 | carga-real | distribuição por tipo (query de S02 § Validação) | dentro da tolerância |
| 05.5 | carga-real | `make seed` de novo | avisa e sai; `count(*)` inalterado |
| 05.6 | carga-real | `psql -c "SELECT finished_at IS NOT NULL FROM seed_control"` | `t` |
| 05.7 | carga-real | `psql -c "SELECT last_analyze IS NOT NULL FROM pg_stat_user_tables WHERE relname='transactions'"` | `t` |

## ROLLBACK
```bash
docker compose exec -T timescaledb psql -U trio -d trio -c "
TRUNCATE reconciliation_events, transactions, accounts;
UPDATE seed_control SET started_at=NULL, finished_at=NULL, total_rows=NULL WHERE id=1;"
```
> Destrutivo: apaga a carga de ~20 min. Confirmar antes de rodar (política de impedimento, Seção 5 do CLAUDE.md).

## STATUS
Estado: BLOQUEADA
Premissas assumidas: seed de 10M custa ~20 min — por isso as etapas que dependem da carga estão separadas das que só precisam do schema
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
