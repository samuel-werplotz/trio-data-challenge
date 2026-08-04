# 10 — LEGADO E MIGRAÇÃO AURORA  [compose]

## ORIGEM
`../vault-estudo/06-Especificacao/S07-Legado-e-Backup.md` § Parte 1 — Schema do legado · § Escolhas deliberadamente "legadas" · § Volume e Bloat proposital · § As duas queries complexas · § Parte 4 — Documentação AWS (escrita, não executada); PDF § 3.2 Parte B

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado ao fechar a etapa 09:
- `timescaledb`: 10.000.000 `transactions`, 500.000 `accounts`, 1.442.266 `reconciliation_events`. 2 CAggs materializados (`cagg_volume_hourly`, `cagg_settlement_latency_daily`), compressão ativa em `transactions` (5,0× total/23,5× tabela), retenção do raw parada (90d), retenção dos CAggs ligada (2 anos). Nenhum dado real alterado desde então.
- `init/timescaledb/05_lgpd_erasure.sql` aplicado: `pgcrypto` habilitado, `lgpd_erasure_log` criada, `PROCEDURE anonimizar_conta(id, requester)`. `desafio-1/lgpd-sanitization.md` cobre as 3 camadas do problema e as 3 estratégias (A/B/C), com a escolha da tabela lateral já implementada em `accounts` desde a etapa 04.
- `desafio-1/scripts/lgpd-erasure-demo.sh` e `desafio-1/scripts/retention-demo.sh` (etapa 08) seguem o mesmo padrão: dado sintético, `trap cleanup EXIT`, nunca tocam nas 500k contas/10M transações reais. Ambos testados e confirmados sem resíduo.
- **`postgres-legado` está de pé e healthy, mas vazio** — só o `00_init.sql` de bootstrap rodou até aqui (nenhum schema de negócio, nenhum seed). É pré-condição limpa para esta etapa: ainda não existe `SERIAL`/bloat/tabela de parâmetros no legado.
- **Nenhuma etapa até aqui tocou ClickHouse ou o pipeline CDC.** O checklist de S09 (LGPD) documentou os passos 3/4 (ClickHouse) como procedimento futuro não executável, porque a etapa 11 (schema ClickHouse) e 13 (pipeline CDC) ainda não rodaram.
- `run_all.sh`: blocos 01–09, **60 pass / 0 fail / 4 skip**. `audit.sh`: 83 pass / 0 fail / 1 warn / 1 skip. Nenhum desvio de plano registrado na etapa 09 (`99-validacao-final.md` não mudou desde a 08).
- Containers de pé: `timescaledb` e `postgres-legado`, ambos healthy.

## ESCOPO
Faz: `desafio-1/schemas/02_legacy.sql` com o schema legado (`SERIAL`, `TIMESTAMP` sem timezone, `VARCHAR` — escolhas legadas deliberadas), seed de 50k usuários + 80k contas + a tabela de **parâmetros de configuração de instituições parceiras**, bloat induzido em 5 rodadas, 2 queries complexas com `EXPLAIN` antes/depois, e `desafio-1/migration-analysis.md` de 1 página.
Não faz: **não provisiona nada na AWS** — a análise de migração é documento escrito, nunca executado. Não usa CDC no legado: a decisão é batch de 5 min (etapa 14).

## PASSOS
1. Escrever `02_legacy.sql` no container `postgres-legado` com as escolhas legadas de S07, cada uma com um comentário dizendo que é deliberada e por quê.
2. Seed de 50k usuários e 80k contas. O PDF § 3.2 B.1 pede **três** grupos de tabelas: usuários, contas e **parâmetros de configuração de instituições parceiras** — esta terceira é a que alimenta o `dict_institutions` da etapa 11 e o ref-sync da 14. Sem ela, o Dictionary não tem origem real.
3. Induzir bloat em 5 rodadas de `UPDATE`/`DELETE` conforme S07 § Volume e Bloat proposital. Declarar abertamente no doc que o bloat é induzido — é preciso ter um problema real para o dashboard da etapa 15 mostrar.
4. Medir o bloat (`pg_stat_user_tables`, razão de páginas mortas) e registrar o número.
5. Escrever as 2 queries complexas de S07 § As duas queries complexas, capturar `EXPLAIN (ANALYZE, BUFFERS)` antes, otimizar, capturar depois — mesmo ritual de medição da etapa 06 (descartar 1ª, mediana de 3).
6. Escrever `desafio-1/migration-analysis.md` (1 página): inventário, estratégia de cutover, critérios de custo/performance/HA, e o que muda ao sair de PostgreSQL autogerenciado para Aurora.
7. Acrescentar o bloco `# --- 10 legado-e-migracao-aurora ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] Schema legado criado no `postgres-legado`, com `SERIAL`/`TIMESTAMP`/`VARCHAR` e comentário de que é deliberado
- [x] 50.000 usuários e 80.000 contas carregados
- [x] Tabela de parâmetros de configuração de instituições parceiras existe e está populada (480 linhas — origem do Dictionary)
- [x] Bloat induzido em 5 rodadas e **medido** com número real (83,3% dead, 70 MB para 80k linhas úteis, ~6×)
- [x] As 2 queries têm `EXPLAIN` antes e depois, com tempo mediano de 3
- [x] `migration-analysis.md` cabe em ~1 página e cobre custo, performance, HA e esforço operacional
- [x] Nenhum recurso AWS foi provisionado — só documento

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 10.1 | compose | `psql -h legado -c "SELECT count(*) FROM users"` | `50000` |
| 10.2 | compose | `psql -h legado -c "SELECT count(*) FROM accounts"` | `80000` |
| 10.3 | compose | `psql -h legado -c "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='accounts'"` | > 0 (bloat presente) |
| 10.7 | compose | `psql -h legado -c "SELECT count(*) FROM institution_config"` | > 0 (origem do Dictionary) |
| 10.4 | local | `ls desafio-1/queries/explains/legacy_q{1,2}_{before,after}.txt` | 4 arquivos |
| 10.5 | local | `test -f desafio-1/migration-analysis.md` | sai 0 |
| 10.6 | local | `! grep -rqi 'aws configure\|terraform apply\|boto3' desafio-1/migration-analysis.md` | sai 0 (nada executado) |

## ROLLBACK
```bash
docker compose exec -T postgres-legado psql -U trio -d legado -c "
DROP TABLE IF EXISTS accounts CASCADE;
DROP TABLE IF EXISTS users CASCADE;"
git checkout -- desafio-1/schemas/02_legacy.sql desafio-1/migration-analysis.md
```

## STATUS
Estado: CONCLUÍDA
Premissas assumidas:
- Schema real aplicado em `init/postgres-legado/01_legacy_schema.sql` + `02_legacy_seed.sql` (o container já tinha rodado o bootstrap, então `docker-entrypoint-initdb.d` não reexecuta sozinho — aplicado via `psql` manual, mesmo padrão das etapas 08/09). Cópia espelho em `desafio-1/schemas/02_legacy.sql`, mesmo padrão de `01_timescale_schema.sql`.
- institution_configs ficou em 480 linhas, não exatamente ~450 de S07 — 15 instituições × 4 chaves × 8 rodadas (1 vigente + 7 histórico) para dar volume real ao filtro temporal da Query B. Ordem de grandeza igual, número exato não é contrato.

Desvios do plano: 2, ambos em `99-validacao-final.md` — teste `06.2` restrito a `q[1-4]_before.txt` (colisão de glob com os novos `legacy_qN_before.txt`); Legacy Q1 não ganhou tempo após ANALYZE (ganho real foi na estimativa de linhas, reportado como está).

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (10.1–10.7)
- [x] run_all.sh sem FAIL — 67 pass / 0 fail / 4 skip
- [x] ESTADO HERDADO da próxima preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → atualizado 99-validacao-final.md
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
