# 12 — BACKFILL E QUERY SUB-SEGUNDO  [carga-real]

## ORIGEM
`../vault-estudo/06-Especificacao/S04-Schema-ClickHouse.md` § O backfill obrigatório · § Como consultar · § A query do Grafana em sub-segundo · § Os quatro fatores que entregam o sub-segundo · § Como medimos; `../vault-estudo/06-Especificacao/S05-Pipeline-CDC.md` § Backfill inicial

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído

## ESTADO HERDADO
Verificado ao fechar a etapa 11:
- `init/clickhouse/01_schema.sql` aplicado no ClickHouse: `transactions_raw` (`ReplacingMergeTree(_version)`, `status` fora do `ORDER BY`), `daily_by_institution`+`mv_daily_by_institution`, `status_funnel`+`mv_status_funnel`, `dict_institutions`. **Todas as tabelas/MVs estão vazias** (0 linhas) — nenhum backfill rodou ainda, essa é justamente esta etapa.
- `dict_institutions` testado e resolvendo dado real do legado (`dictGetOrDefault(...'001'...)` → "Instituição Parceira 1"), fonte é `postgres-legado.partner_institutions` (15 linhas, etapa 10).
- **4 colunas de estado agregado saíram diferentes do DDL literal de S04**: `avg_settle_seconds` (em `daily_by_institution`) e `avg_seconds`/`p50_seconds`/`p95_seconds` (em `status_funnel`) são `AggregateFunction(_, Nullable(Float32))`, não `AggregateFunction(_, Float32)` — porque `settlement_seconds` é `Nullable`. Isso importa para esta etapa: o backfill via `INSERT SELECT` precisa gerar `avgState`/`quantileState` sobre a mesma coluna nullable, senão bate no mesmo `CANNOT_CONVERT_TYPE` que a criação das MVs bateu.
- **`docker compose --profile core up` está quebrado** (bug pré-existente, não desta etapa): `grafana` depende de `prometheus`, que só está no perfil `full`. `clickhouse` foi subido por nome de serviço direto (`docker compose up -d clickhouse`), contornando o filtro de perfil — mesma abordagem que esta etapa deve usar se precisar subir mais serviços.
- `postgres-legado`: inalterado desde a etapa 10 (15 instituições, 480 configs, 50k usuários, 80k contas, bloat induzido presente).
- `timescaledb`: inalterado desde a etapa 09 — 10.000.000 `transactions`, 2 CAggs, compressão e retenção ativas. Esta é a fonte do backfill PG→ClickHouse desta etapa (direto, sem Kafka, por decisão de S05).
- Containers de pé: `timescaledb`, `postgres-legado`, `clickhouse`, todos healthy.
- `run_all.sh`: blocos 01–11, **74 pass / 0 fail / 3 skip**. `audit.sh`: 83 pass / 0 fail / 1 warn / 1 skip. Dois desvios em `99-validacao-final.md`: tipo `Nullable` nas 4 colunas de estado; bug de `profiles`/`depends_on` do compose (contornado, não corrigido — fora do escopo de qualquer etapa até agora).

## ESCOPO
Faz: backfill mês a mês de `transactions` do PostgreSQL direto para `transactions_raw` no ClickHouse, `INSERT SELECT` para popular as 2 MVs, e a medição da query Pix "24h vs D-1" via `system.query_log` comprovando sub-segundo com número.
Não faz: **não passa pelo Kafka** — o backfill dos 10M é direto PG→ClickHouse, por decisão de S05. Não registra o conector Debezium: é a etapa 13, e só depois do backfill (ordem obrigatória).

## PASSOS
1. Backfill de `transactions_raw` em **blocos mensais** conforme S05 § Backfill inicial, lendo direto do PostgreSQL — 12 blocos, um por mês.
2. Conferir a contagem por mês contra a origem antes de seguir.
3. Popular as 2 MVs com `INSERT SELECT` a partir de `transactions_raw` — o backfill é obrigatório porque as MVs foram criadas sem `POPULATE` e só capturam o que chega depois.
4. Conferir os agregados das MVs contra a mesma agregação feita direto em `transactions_raw`.
5. Escrever a query do Grafana (volume Pix das últimas 24h vs D-1) conforme S04 § A query do Grafana em sub-segundo.
6. Medir conforme S04 § Como medimos: executar, ler `query_duration_ms` e `read_rows` em `system.query_log`, descartar a 1ª execução e registrar a mediana de 3.
7. Registrar o número real e os 4 fatores que entregam o sub-segundo (S04 § Os quatro fatores).
8. Acrescentar o bloco `# --- 12 backfill-e-query-subsegundo ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] `SELECT count(*) FROM transactions_raw` = 10.000.000
- [x] `count() FINAL` bate com o `count(*)` (sem duplicata introduzida pelo backfill)
- [x] Contagem por mês bate com a origem nos 12 meses
- [x] As 2 MVs estão populadas e seus agregados batem com a agregação direta na raw
- [x] Query Pix 24h vs D-1 mede **< 1000 ms** em `system.query_log`, mediana de 3 (medido: 7ms)
- [x] O número medido está registrado no `REPORT.md`, com `read_rows` (5.882)
- [x] Backfill não passou pelo Kafka (`postgresql()` table function, direto PG→CH)

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 12.1 | carga-real | `clickhouse-client -q "SELECT count(*) FROM transactions_raw"` | `10000000` |
| 12.2 | carga-real | `clickhouse-client -q "SELECT count() FROM transactions_raw FINAL"` | igual ao 12.1 |
| 12.3 | carga-real | contagem por mês CH vs PG | igual nos 12 meses |
| 12.4 | carga-real | `clickhouse-client -q "SELECT count(*) FROM daily_summary"` | > 0 |
| 12.5 | carga-real | `SELECT query_duration_ms FROM system.query_log WHERE ... ORDER BY event_time DESC LIMIT 3` | mediana < 1000 |
| 12.6 | carga-real | agregado da MV vs agregado direto na raw | mesma soma |

## ROLLBACK
```bash
docker compose exec -T clickhouse clickhouse-client -q "
TRUNCATE TABLE transactions_raw;
TRUNCATE TABLE daily_summary;
TRUNCATE TABLE status_funnel;"
```
> Destrutivo: apaga o backfill. O schema (etapa 11) permanece. Confirmar antes de rodar.

## STATUS
Estado: CONCLUÍDA
Premissas assumidas:
- `scripts/backfill-clickhouse.sh` na raiz de `scripts/`, não em `desafio-1/scripts/` — este é backfill de infraestrutura (PG→CH), não um demo de feature do desafio 1 como `retention-demo.sh`/`lgpd-erasure-demo.sh`.
- Query do Grafana salva em `desafio-1/queries/grafana_pix_24h_vs_d1.sql` (não existia local definido no ESCOPO).

Desvios do plano: 3, todos em `99-validacao-final.md` — MV já ativa duplicando o backfill (achado real, não do plano); query ilustrativa de S04 não compilava contra o schema real (`countIfMerge` vs `status` no GROUP BY); teste `11.6` invalidado por avanço legítimo de escopo.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (12.1–12.7)
- [x] run_all.sh sem FAIL — 81 pass / 0 fail / 3 skip
- [x] ESTADO HERDADO da próxima preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → atualizado 99-validacao-final.md
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
