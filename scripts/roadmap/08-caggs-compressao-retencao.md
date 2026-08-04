# 08 — CAGGS, COMPRESSÃO E RETENÇÃO  [carga-real]

## ORIGEM
`../vault-estudo/06-Especificacao/S03-CAggs-e-Politicas.md` § CAgg 1 — Volume e valor por tipo, por hora · § Materialização inicial em lotes · § Política de atualização · § CAgg 2 — P95/P99 de latência por instituição, por dia · § O ponto técnico central: percentil não é somável · § Compressão · § `segmentby` — a decisão que importa · § Verificação da taxa · § Retenção · § Conflito entre retenção e o desafio · § Jobs de background

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído

## ESTADO HERDADO
Verificado ao fechar a etapa 07:
- `init/timescaledb/03_indexes.sql` aplicado, com `CREATE INDEX IF NOT EXISTS` (idempotente): `idx_recon_divergent` (parcial, `WHERE abs(difference) > 0.01`), `idx_accounts_id_covering` (`INCLUDE`), `idx_tx_institution_created` (`INCLUDE`), `idx_tx_dup_detection` (parcial, `WHERE status IN ('settled','pending')`). `transactions` tem 4 índices no total (2 implícitos + 2 destes).
- Queries otimizadas: `q2_divergencias_reconciliacao_optimized.sql`, `q3_top_instituicoes_optimized.sql`, `q4_optimized.sql` (window function), `bonus_gapfill_48h.sql`. **Q1 continua só na versão ingênua** — sua otimização é ler do CAgg, que é escopo desta etapa 08.
- `explains/q{2,3,4}_after.txt` gravados. Medianas finais: Q2 1.584→1.511ms (índice usado mas sem ganho — gargalo é o join com transactions), Q3 1.285→394ms (3,3×), Q4 2.814→1.274ms (2,2×). Q1 tem só `q1_before.txt` (12.115ms) — **esta etapa deve gerar `q1_after.txt`** com a versão que lê de `cagg_volume_hourly`.
- `run-explains.sh` agora recebe `before|after` como argumento e sabe quais arquivos medir em cada modo. Ao acrescentar a Q1 otimizada, incluir no ramo `after`.
- `desafio-1/REPORT.md` criado com a tabela consolidada antes/depois; a linha de Q1 está com "(etapa 08)" no lugar do "depois" — **preencher aqui**. Também documenta o índice que não melhorou (Q2) e a limitação de Q4 (0 duplicatas no dataset sintético).
- **`reconciliation_events` foi regerado nesta etapa** (1.442.266 linhas): a versão da etapa 05 tinha divergência percentual (86% das linhas divergiam) e `reconciled_at = now()` para todas. Corrigido para ~8% divergente (114.953 linhas) e `reconciled_at` distribuído de set/2025 a ago/2026. Os 10M de `transactions` **não** foram tocados. Desvio registrado em `99-validacao-final.md`.
- Testes `04.6` e `06.3` do `run_all.sh` foram reescritos: asseriam "nenhum índice em transactions", que a etapa 07 invalida por design. Agora checam os índices implícitos por nome e a ausência de `Index Scan using idx_` nos `qN_before.txt`. Desvio registrado em `99-validacao-final.md`.
- Nenhum CAgg existe ainda (`timescaledb_information.continuous_aggregates` = 0), nenhuma política de compressão ou retenção — pré-condição limpa para esta etapa.
- `run_all.sh`: blocos 01-07, 40 pass / 0 fail / 4 skip. `audit.sh`: 83 pass / 0 fail / 1 warn / 1 skip (o script foi corrigido para enxergar `concluidas/` — não há mais FAIL "conhecido" para ignorar).
- Containers de pé: `timescaledb` (com `shm_size: 1gb`) e `postgres-legado`, ambos healthy.

## ESCOPO
Faz: `init/timescaledb/04_caggs_policies.sql` — `cagg_volume_hourly` e `cagg_settlement_latency_daily`, ambos `WITH NO DATA` com materialização em lotes trimestrais; políticas de refresh com `end_offset` de 1h; compressão com `segmentby`/`orderby`; política de retenção **criada e desabilitada**; e `scripts/retention-demo.sh`. Mede a taxa de compressão.
Não faz: não habilita a política de retenção (o dataset é de 12 meses e a retenção é de 90 dias — habilitar apagaria 9 meses de dado); não usa `POPULATE`/refresh de uma vez só.

## PASSOS
1. Criar `cagg_volume_hourly`: `time_bucket` de 1h, group by `type` + `status`, `WITH NO DATA`.
2. Criar `cagg_settlement_latency_daily`: bucket de 1 dia, `percentile_agg` por instituição. Comentar no SQL que percentil **não é somável** — daí o TDigest em vez de `percentile_cont` sobre o agregado.
3. Materializar ambos com `refresh_continuous_aggregate` em **lotes trimestrais**, não numa chamada só.
4. Criar as políticas de refresh com `end_offset` de 1h, comentando o porquê: o bucket corrente ainda recebe escrita, e refrescá-lo produziria número que muda debaixo do dashboard.
5. Habilitar compressão com `segmentby='source_institution, type'` e `orderby='created_at DESC, status'`; política de compressão de 7 dias. Medir a taxa com a query de S03 § Verificação da taxa.
6. Criar a política de retenção de **90 dias sobre o raw** e **desabilitá-la** com `alter_job(..., scheduled => false)`. Comentar o conflito no SQL.
7. Criar a política de retenção de **2 anos sobre os 2 CAggs** — o PDF § 3.2 A.5 pede as duas retenções ("raw 90 dias, continuous aggregates 2 anos"), e só a do raw estava prevista. Esta pode ficar **habilitada**: o dataset tem 12 meses, então 2 anos não apaga nada — é a política correta e inofensiva. Comentar essa assimetria no SQL: a do raw fica parada por conflito com o dataset, a do CAgg não.
8. Escrever `scripts/retention-demo.sh`, que demonstra a retenção funcionando sem destruir o dataset.
9. Conferir os jobs em `timescaledb_information.jobs` e acrescentar o bloco `# --- 08 caggs-compressao-retencao ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] Os 2 CAggs existem e estão materializados nos 12 meses
- [ ] Ambos foram criados `WITH NO DATA` e materializados em lotes trimestrais
- [ ] Política de refresh de cada CAgg tem `end_offset` de 1h
- [ ] Compressão ativa com `segmentby` e `orderby` exatamente como S03
- [ ] Taxa de compressão medida e registrada com número real
- [ ] Política de retenção de 90d sobre o raw **existe** e está com `scheduled = false`
- [ ] Política de retenção de **2 anos sobre os 2 CAggs** existe (PDF § 3.2 A.5)
- [ ] `count(*)` de `transactions` continua 10.000.000 depois de tudo
- [ ] `retention-demo.sh` roda sem apagar dado do dataset principal
- [ ] Q1 e Q3 reexecutadas lendo do CAgg, com o ganho registrado no `REPORT.md`

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 08.1 | carga-real | `psql -c "SELECT count(*) FROM timescaledb_information.continuous_aggregates"` | `2` |
| 08.2 | carga-real | `psql -c "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention' AND scheduled"` | `0` |
| 08.3 | carga-real | `psql -c "SELECT count(*) FROM timescaledb_information.jobs WHERE proc_name='policy_retention'"` | `1` (existe, mas parada) |
| 08.4 | carga-real | `psql -c "SELECT count(*) FROM transactions"` | `10000000` |
| 08.5 | carga-real | query de taxa de compressão de S03 | razão > 1, registrada |
| 08.6 | carga-real | `psql -c "SELECT count(*) FROM cagg_volume_hourly"` | > 0 (materializado) |
| 08.7 | local | `bash -n scripts/retention-demo.sh` | sai 0 |

## ROLLBACK
```bash
docker compose exec -T timescaledb psql -U trio -d trio -c "
DROP MATERIALIZED VIEW IF EXISTS cagg_settlement_latency_daily CASCADE;
DROP MATERIALIZED VIEW IF EXISTS cagg_volume_hourly CASCADE;
SELECT remove_compression_policy('transactions', if_exists => true);
SELECT remove_retention_policy('transactions', if_exists => true);
ALTER TABLE transactions SET (timescaledb.compress = false);"
git checkout -- init/timescaledb/04_caggs_policies.sql
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
