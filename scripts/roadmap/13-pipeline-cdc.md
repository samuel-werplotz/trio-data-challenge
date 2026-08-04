# 13 — PIPELINE CDC  [carga-real]

## ORIGEM
`../vault-estudo/06-Especificacao/S05-Pipeline-CDC.md` § Configuração do conector Debezium · § As decisões críticas · § O consumidor · § O laço principal · § Transformação do evento · § Micro-batch · § Idempotência · § Tratamento de falhas · § Métricas expostas em `:8001/metrics` · § Demonstração de mutação · § Ordem de validação no Dia 4

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído
- [ ] 2h sem CDC funcionando sobre hypertable → **PARAR, relatar, aguardar decisão**. Acionar o plano B (micro-batch por watermark) é decisão de arquitetura, não do agente — mesmo estando previsto em S05

## ESTADO HERDADO
Verificado ao fechar a etapa 12:
- **Backfill completo**: `transactions_raw` com 10.000.000 linhas, `count() FINAL` idêntico (sem duplicata), contagem por mês bate exatamente com o TimescaleDB nos 12 meses. As 2 MVs (`daily_by_institution`, `status_funnel`) populadas e conferidas contra agregação direta na raw. Backfill rodou **direto PG→ClickHouse via `postgresql()`**, sem Kafka — `scripts/backfill-clickhouse.sh`.
- **Ordem obrigatória cumprida até aqui**: schema ClickHouse (11) → backfill raw (12) → backfill MVs (12) → **falta só o conector Debezium**, que é exatamente o escopo desta etapa. Registrá-lo antes do backfill teria causado corrida entre as duas escritas — não é o caso, backfill já terminou.
- **Armadilha real encontrada no backfill**: as 2 MVs já eram gatilho de inserção ativo quando o backfill do raw rodou, e capturaram os 12 blocos sozinhas — um `INSERT SELECT` de backfill rodado depois duplicou tudo (20M vs 10M). Corrigido truncando e reaplicando uma vez. **Relevante para esta etapa**: se o conector Debezium for registrado e depois algum re-processamento de MV for necessário, a mesma armadilha se aplica — checar se a MV já capturou antes de rodar `INSERT SELECT` de novo.
- **Query do Grafana Pix 24h vs D-1 medida**: mediana 7ms, muito abaixo do alvo de 1000ms, `read_rows`=5.882 (lê da MV agregada). A query ilustrativa de S04 (`countIfMerge`) não rodava contra o schema real — corrigida em `desafio-1/queries/grafana_pix_24h_vs_d1.sql`.
- `postgres-legado`: inalterado desde a etapa 10 — schema, seed e bloat presentes; é a origem do `dict_institutions` usado pelas queries do ClickHouse.
- `timescaledb`: inalterado desde a etapa 09 — 10.000.000 `transactions`, 2 CAggs, compressão e retenção ativas. **É a origem que o Debezium vai capturar via CDC** a partir de agora.
- **`docker compose --profile core` continua quebrado** (bug pré-existente, `grafana`→`prometheus`, não desta trilha de etapas) — subir serviços novos por nome direto (`docker compose up -d <serviço>`), não via `--profile`.
- Containers de pé: `timescaledb`, `postgres-legado`, `clickhouse`, todos healthy. **Redpanda/Debezium Connect ainda não subiram** — são desta etapa.
- `run_all.sh`: blocos 01–12, **81 pass / 0 fail / 3 skip**. `audit.sh`: 83 pass / 0 fail / 1 warn / 1 skip. Três desvios em `99-validacao-final.md`: duplicação do backfill de MV corrigida; query ilustrativa de S04 corrigida; teste `11.6` ajustado por avanço de escopo.

## ESCOPO
Faz: publication manual com `publish_via_partition_root = true`, registro do conector Debezium (`pgoutput`, `snapshot.mode: no_data`, RegexRouter como rede de segurança), consumidor Python com DLQ, retry exponencial e métricas Prometheus em `:8001/metrics`, e `scripts/demo-mutation.sh`.
Não faz: não aciona o plano B por conta própria; não refaz o backfill (etapa 12); não altera o schema do ClickHouse.

## PASSOS
1. Criar a publication **manualmente** com `publish_via_partition_root = true` — sem isso o Debezium emite eventos com o nome do chunk, não da hypertable.
2. Registrar o conector com `plugin.name: pgoutput` e `snapshot.mode: no_data` (o histórico já foi pelo backfill da etapa 12, não deve vir pelo Kafka).
3. Configurar o RegexRouter como **rede de segurança**: se algum evento escapar com nome de chunk, o roteador normaliza para o tópico da hypertable. Comentar que é redundância proposital.
4. Implementar o consumidor conforme S05 § O consumidor: laço principal, transformação do evento, micro-batch, e idempotência via `_version`.
5. Implementar o tratamento de falhas: retry exponencial e DLQ para o que não recupera.
6. Expor as métricas de S05 § Métricas em `:8001/metrics`.
7. Escrever `scripts/demo-mutation.sh` incluindo o **passo 7**: a consulta que mostra 2 linhas **sem** `FINAL` — evidência visível de como o `ReplacingMergeTree` guarda as versões antes do merge.
8. Rodar o teste de idempotência: reprocessar do offset 0 e conferir que `count() FINAL` não muda. Acrescentar o bloco `# --- 13 pipeline-cdc ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] Publication existe com `publish_via_partition_root = true`
- [ ] Conector registrado e em estado `RUNNING`
- [ ] `snapshot.mode` é `no_data`
- [ ] Um `UPDATE` no PostgreSQL aparece no ClickHouse em tempo demonstrável
- [ ] `demo-mutation.sh` roda ponta a ponta e o passo 7 mostra 2 linhas sem `FINAL`, 1 com `FINAL`
- [ ] `:8001/metrics` responde com as métricas de S05
- [ ] DLQ recebe evento inválido em vez de derrubar o consumidor
- [ ] Reprocessar do offset 0 **não** muda `count() FINAL` (idempotência)

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 13.1 | carga-real | `psql -c "SELECT pubname, pubviaroot FROM pg_publication"` | `pubviaroot = t` |
| 13.2 | carga-real | `curl -s localhost:8083/connectors/<nome>/status \| jq -r .connector.state` | `RUNNING` |
| 13.3 | carga-real | `curl -s localhost:8001/metrics \| grep -c '^trio_'` | > 0 |
| 13.4 | carga-real | `bash scripts/demo-mutation.sh` | sai 0; passo 7 mostra 2 sem FINAL / 1 com FINAL |
| 13.5 | carga-real | `count() FINAL` antes e depois de reprocessar do offset 0 | mesmo valor |
| 13.6 | carga-real | publicar evento malformado | vai para a DLQ; consumidor segue vivo |

## ROLLBACK
```bash
curl -s -X DELETE localhost:8083/connectors/trio-transactions-connector
docker compose exec -T timescaledb psql -U trio -d trio -c "
DROP PUBLICATION IF EXISTS trio_pub;
SELECT pg_drop_replication_slot('trio_slot') WHERE EXISTS (
  SELECT 1 FROM pg_replication_slots WHERE slot_name='trio_slot');"
```
> Ajustar os nomes ao que a etapa de fato criou. Não apaga dado do ClickHouse.

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
