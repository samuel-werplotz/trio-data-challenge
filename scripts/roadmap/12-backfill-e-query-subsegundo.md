# 12 — BACKFILL E QUERY SUB-SEGUNDO  [carga-real]

## ORIGEM
`../vault-estudo/06-Especificacao/S04-Schema-ClickHouse.md` § O backfill obrigatório · § Como consultar · § A query do Grafana em sub-segundo · § Os quatro fatores que entregam o sub-segundo · § Como medimos; `../vault-estudo/06-Especificacao/S05-Pipeline-CDC.md` § Backfill inicial

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído

## ESTADO HERDADO
<preenchido pela etapa 11 ao fechar>

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
- [ ] `SELECT count(*) FROM transactions_raw` = 10.000.000
- [ ] `count() FINAL` bate com o `count(*)` (sem duplicata introduzida pelo backfill)
- [ ] Contagem por mês bate com a origem nos 12 meses
- [ ] As 2 MVs estão populadas e seus agregados batem com a agregação direta na raw
- [ ] Query Pix 24h vs D-1 mede **< 1000 ms** em `system.query_log`, mediana de 3
- [ ] O número medido está registrado no `REPORT.md`, com `read_rows`
- [ ] Backfill não passou pelo Kafka

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
