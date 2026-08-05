# Trio Data Challenge — Engenheiro de Dados Sênior

Plataforma de dados para infraestrutura de pagamentos: TimescaleDB transacional
→ ClickHouse analítico, com PostgreSQL legado como fonte de referência,
observabilidade e procedimentos de operação.

**10.000.000 de transações** carregadas em 12 meses, pipeline rodando, 4
dashboards e 6 alertas ativos.

> **Tem 2 minutos?** → [`docs/SUMARIO-EXECUTIVO.md`](docs/SUMARIO-EXECUTIVO.md)
> — o que foi construído, os 5 números medidos, os 3 riscos com dono e o
> roadmap 30/60/90. Custo em produção: [`docs/CUSTO-AWS.md`](docs/CUSTO-AWS.md).

---

## Quick Start

```bash
cp .env.example .env
docker compose up -d
```

Sobe os 13 serviços. O `seed` é **idempotente** — se o dado já existe, ele
registra e sai sem regravar. A primeira execução carrega os 10M em ~2 min.

```bash
# Acompanhar até tudo ficar healthy
docker compose ps
```

Para subir também o experimento com CDC/Debezium (artefato de decisão, **fora**
do caminho principal — ver `desafio-2/ADR.md`):

```bash
docker compose --profile cdc-experimento up -d
```

### Verificação rápida

```bash
# 10.000.000 na origem
docker exec trio-timescaledb psql -U trio -d trio_transactions -tAc "SELECT count(*) FROM transactions"

# 10.000.000 no destino
docker exec trio-clickhouse clickhouse-client -u trio --password trio2024 -q "SELECT count() FROM trio_analytics.transactions_raw"

# API servindo o ClickHouse
curl -s localhost:8000/ops/volume-now | head -c 300

# Suíte de regressão completa
bash scripts/tests/run_all.sh
```

---

## Serviços

| Serviço | Porta | Descrição |
|---|---|---|
| TimescaleDB | `5432` | Banco transacional principal (hypertable, CAggs, compressão) |
| PostgreSQL Legado | `5433` | Legado — candidato a Aurora/RDS; fonte do Dictionary |
| ClickHouse (HTTP / Native) | `8123` / `9000` | Motor analítico — aplicações e Data Champions |
| **API** | `8000` | FastAPI servindo o ClickHouse (JSON) |
| **sync-worker** | `8001` | Pipeline TimescaleDB → ClickHouse (métricas Prometheus) |
| **ref-sync** | `8002` | Legado → Dictionary, batch de 5 min |
| Grafana | `3000` | 4 dashboards (admin/admin) |
| Prometheus | `9090` | Coleta + 6 regras de alerta |
| MinIO | `9002` / `9001` | Destino S3-compatível dos backups / console |

> MinIO publica na **9002**, não 9000: a 9000 é a porta nativa do ClickHouse.

---

## O que está entregue, e onde

### Desafio 1 — Modelagem e Performance

| Requisito | Onde |
|---|---|
| Schema + hypertable (chunk de 1 dia, justificado) | `init/timescaledb/01_schema.sql` · `desafio-1/REPORT.md` |
| 10M em 12 meses, distribuição realista | `desafio-1/seed/` |
| CAggs: volume/hora e P95/P99 por instituição/dia | `init/timescaledb/04_caggs_policies.sql` |
| Retenção (90d raw / 2 anos CAgg) e compressão 7d | idem · `REPORT.md` § Retenção |
| Q1–Q4 com `EXPLAIN ANALYZE` antes/depois | `desafio-1/queries/` · `queries/explains/` |
| `time_bucket_gapfill` + `locf` (48h) | `desafio-1/queries/bonus_gapfill_48h.sql` |
| Sanitização LGPD de chunks com PII | `desafio-1/lgpd-sanitization.md` |
| Legado: schema, 2 queries otimizadas, bloat | `init/postgres-legado/` · `queries/legacy_q*.sql` |
| Análise PostgreSQL → Aurora | `desafio-1/migration-analysis.md` |
| ClickHouse: engine, `ORDER BY`, `PARTITION BY`, codecs | `init/clickhouse/01_schema.sql` |
| 2 MVs pré-agregadas + Dictionary | idem · `REPORT.md` § Dictionary vs JOIN |
| Query Grafana Pix 24h vs D-1, sub-segundo | `queries/grafana_pix_24h_vs_d1.sql` — **12 ms** |
| ClickHouse servindo aplicação | `desafio-2/pipeline/api/` |

**Resultados medidos** (`desafio-1/REPORT.md`): Q1 **12.115 ms → 23 ms (521×)`;
Q3 via CAgg **383×**; compressão **5,5×**; query do painel **12 ms** contra alvo
de 1000 ms.

### Desafio 2 — Pipeline e Arquitetura

| Requisito | Onde |
|---|---|
| Pipeline TimescaleDB → ClickHouse | `desafio-2/pipeline/sync-worker/` |
| Idempotência, retry, DLQ, observabilidade | idem · `metrics.py` |
| Mutação `pending → settled` demonstrada | `desafio-2/demo-sync-worker.sh` |
| Pipeline de referência (legado → Dictionary) | `desafio-2/pipeline/ref-sync/` |
| Diagramas (componentes, AWS, SLAs, falhas) | `desafio-2/diagrams/` (3 `.mmd`) |
| ADR com as 4 perguntas | `desafio-2/ADR.md` |

> **Por que micro-batch e não CDC:** o Debezium foi construído, medido e
> descartado — `publish_via_partition_root` não funciona sobre hypertable
> (causa provada em `desafio-2/ADR.md`). O experimento ficou no repositório sob
> o profile `cdc-experimento`.

### Desafio 3 — Operação e Resiliência

| Requisito | Onde |
|---|---|
| Backup dos 3 bancos (pgBackRest → MinIO) | `desafio-3/backup/` |
| Recovery drill com RTO/RPO medidos | `desafio-3/backup/restore-drill.sh` — **RTO 22 s** |
| Runbook: storage em 92% | `desafio-3/runbook.md` |
| 4 dashboards Grafana | `init/grafana/dashboards/` |
| 6 alertas com CloudWatch/SNS | `desafio-3/grafana/alertas.md` |
| Incidente SEV-1 (7 hipóteses) | `desafio-3/incident-response.md` |

---

## Demonstrações

```bash
# Pipeline: INSERT → pending → UPDATE → settled, com idempotência
bash desafio-2/demo-sync-worker.sh

# Retenção: prova a política sem destruir dado (chunks sintéticos em 2020)
bash desafio-1/scripts/retention-demo.sh

# LGPD: anonimização sobre conta sintética, com auditoria
bash desafio-1/scripts/lgpd-erasure-demo.sh

# Recovery: perda simulada + restore em instância paralela (porta 5499)
bash desafio-3/backup/restore-drill.sh
```

Todos os scripts limpam o que criam e conferem as contagens ao final.

---

## Testes

```bash
bash scripts/tests/run_all.sh   # suíte de regressão do produto (171 testes)
bash scripts/tests/audit.sh     # auditoria do plano e do rastreio do PDF
```

`SKIP` indica pré-condição ausente no ambiente (ex.: `make` não instalado neste
Windows), **não** falha.

---

## Documentos que valem a leitura

| Documento | Por quê |
|---|---|
| `desafio-1/REPORT.md` | Medições reais, incluindo **o índice que não melhorou** e a compressão que compete com os índices |
| `desafio-2/ADR.md` | Decisões e **consequências negativas**; por que o CDC foi descartado |
| `desafio-3/incident-response.md` | Árvore de hipóteses e ações preventivas, não só detectivas |
| `AUDITORIA-E-REPLANEJAMENTO.md` | Matriz de rastreabilidade requisito a requisito |

---

## Estrutura

```
trio-data-challenge/
├── docker-compose.yml
├── init/                    ← schema e config dos 3 bancos + Grafana/Prometheus
├── desafio-1/               ← schemas, seed, queries, REPORT, migração, LGPD
├── desafio-2/               ← pipeline (sync-worker, ref-sync, api), diagramas, ADR
├── desafio-3/               ← backup, grafana (alertas), runbook, incidente
├── scripts/                 ← testes, health-check, backfill, roadmap de execução
└── docs/
```
