# Trio Data Challenge — Engenheiro de Dados Sênior

Plataforma de dados para infraestrutura de pagamentos: **TimescaleDB**
transacional → **ClickHouse** analítico, com **PostgreSQL legado** como fonte de
referência, observabilidade, backup testado e procedimentos de operação.

**10.000.000 de transações** em 12 meses, pipeline com freshness de ~10 s, 4
dashboards, 6 alertas e 171 testes de regressão. Sobe com um comando.

---

## Quick Start

Quatro comandos, ≈ 6 minutos do zero:

```bash
cp .env.example .env
bash desafio-3/backup/gen-certs.sh
docker compose up -d
bash scripts/bootstrap.sh
```

| Comando | O que faz | Quando repetir |
|---|---|---|
| `gen-certs.sh` | Gera o certificado HTTPS do MinIO. **Segundos** | Uma vez por clone |
| `docker compose up -d` | Sobe os 13 serviços e carrega os 10M | Sempre |
| `bootstrap.sh` | Materializa CAggs, comprime, faz o backfill do ClickHouse, cria perfil de acesso e stanzas de backup | Sempre — é idempotente |

**Por que o certificado vem antes do `up`:** a chave privada não é versionada
(`.gitignore`), então num clone limpo ela não existe. Sem ela o MinIO não sobe,
o bucket de backup não é criado e o `archive_command` do WAL falha nos dois
Postgres.

**Por que o `up` sozinho não basta:** a materialização dos continuous aggregates
não roda dentro de transação, então o `init/` do Postgres não consegue fazê-la.
Sem os CAggs, a query Q1 continua levando 12 segundos em vez de 23 ms.

**Tempos medidos numa execução do zero** (volumes apagados):

| Passo | Tempo |
|---|---|
| `up` até todos os healthchecks verdes | **20 s** |
| Seed dos 10M (automático, em paralelo) | **168 s** |
| CAggs + compressão de 331 chunks | **82 s** |
| Backfill do ClickHouse | **58 s** |
| Backup full dos 3 bancos | **53 s** |
| **Total, do zero ao ambiente completo** | **≈ 6 min** |

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

Depois disso, os dashboards estão em **http://localhost:3000** (`admin`/`admin`)
— veja a nota logo abaixo sobre por que eles aparecem **parados**.

---

## Os dashboards, e por que eles começam parados

Quatro dashboards provisionados automaticamente, sem importar nada:
**Trio · Pipeline**, **Trio · TimescaleDB**, **Trio · ClickHouse** e
**Trio · PostgreSQL Legado**.

> **O painel de Pipeline vai mostrar lag zero e throughput zero — e isso está
> correto.** O seed carrega 12 meses de histórico e termina; a partir daí nenhuma
> transação nova entra, então o worker roda seus ciclos de 10 s, não encontra
> linhas e não grava nada. Pipeline ocioso, não pipeline quebrado.

Para ver os painéis reagirem, gere movimento na origem:

```bash
# Opção 1 — a demonstração completa: INSERT → pending → UPDATE → settled
bash desafio-2/demo-sync-worker.sh

# Opção 2 — só volume, para ver os gráficos se moverem
docker exec trio-timescaledb psql -U trio -d trio_transactions -c \
  "INSERT INTO transactions (external_id, source_institution, destination_institution,
                             source_account_id, destination_account_id, amount, type, status)
   SELECT gen_random_uuid(), '001', '237', 1, 2, 100.50, 'pix', 'pending'
     FROM generate_series(1,5000)"
```

Com **Trio · Pipeline** aberto, em ~10 s o lag sobe e volta, o throughput salta,
e *"tempo desde a última gravação bem-sucedida"* reseta. Esse painel é um
timestamp que envelhece, não um contador: contador que para de crescer é
indistinguível de "não houve movimento", enquanto timestamp velho é afirmativo.

---

## Dois atalhos, se o tempo for curto

**Tem 2 minutos?** → [`docs/SUMARIO-EXECUTIVO.md`](docs/SUMARIO-EXECUTIVO.md).
Os 5 números, os 3 riscos com dono e prazo, e o roadmap 30/60/90.

**Vai avaliar como isto foi feito?** → [`docs/METODOLOGIA.md`](docs/METODOLOGIA.md).
Usei IA generativa nesta entrega, e esse documento explica exatamente como:
arquitetura decidida antes do código, IA restrita a executar dentro de contrato
fechado, e todo resultado medido contra os 10M antes de entrar no repositório.

---

## Os documentos que importam

Na ordem de quem lê. Todo o resto é código ou teste.

| # | Documento | Responde |
|---|---|---|
| 1 | [SUMARIO-EXECUTIVO](docs/SUMARIO-EXECUTIVO.md) | 5 números, 3 riscos com dono, roadmap 30/60/90 |
| 2 | [METODOLOGIA](docs/METODOLOGIA.md) | **Como usei IA sem terceirizar a engenharia** |
| 3 | [desafio-1/REPORT](desafio-1/REPORT.md) | As medições — incluindo **o índice que não melhorou** e **o P95 que respondia a pergunta errada** |
| 4 | [desafio-2/ADR](desafio-2/ADR.md) | Decisões, SLOs e **consequências negativas**; por que o CDC foi descartado |
| 5 | [PERGUNTAS-DA-BANCA](docs/PERGUNTAS-DA-BANCA.md) | As 5 perguntas do PDF § 7, respondidas |
| 6 | [DATA-CHAMPIONS](docs/DATA-CHAMPIONS.md) | Como um analista usa a plataforma sem ajuda |
| 7 | [SEGURANCA-E-GOVERNANCA](docs/SEGURANCA-E-GOVERNANCA.md) | Perfis, cifra, auditoria de PII, BCB 4.658 |
| 8 | [desafio-3/incident-response](desafio-3/incident-response.md) | O que fazer às 3h da manhã |
| 9 | [CUSTO-AWS](docs/CUSTO-AWS.md) | **Quanto isto custa em produção** — US$ 844/mês, e US$ 2.700 no cenário 10× |

Complementos:
[PROCEDIMENTOS-PRODUCAO](desafio-2/PROCEDIMENTOS-PRODUCAO.md) (novo consumidor e
troca de engine sem downtime — as perguntas 2 e 3 do PDF § 7) ·
[HA-CLICKHOUSE](docs/HA-CLICKHOUSE.md) (o modo replicado, comprovado por teste
de failover) ·
[desafio-3/runbook](desafio-3/runbook.md) (storage em 92%).

---

## Os 5 números

| | Resultado | O que significa |
|---|---|---|
| **Query analítica** | 12.115 ms → **23 ms** (521×) | O relatório que travava o banco virou consulta interativa |
| **Compressão** | **5,0×** (23,5× só na tabela) | 2.674 MB → 536 MB |
| **Freshness do pipeline** | **~10 s** (alvo < 30 s) | O painel mostra o agora |
| **RTO / RPO medidos** | **22 s / 60 s** | Restore executado de verdade, com perda simulada |
| **Custo estimado em produção** | **≈ US$ 844/mês** | ≈ US$ 2.700 no cenário de 10× — [abertura linha a linha](docs/CUSTO-AWS.md) |

**Sobre o custo:** o número acima não é chute de ordem de grandeza.
[`docs/CUSTO-AWS.md`](docs/CUSTO-AWS.md) abre os dois cenários (10M e 100M
transações/mês) item por item, **com a premissa de dimensionamento ao lado de
cada linha** — é a premissa que se discute numa aprovação de orçamento, não o
total. Inclui o que a fila gerenciada custaria (≈ US$ 620/mês, 73% da
plataforma) e por isso foi adiada, a diferença entre Aurora e RDS, e o que a
estimativa **não** cobre.

---

## O que está entregue, e onde

### Desafio 1 — Modelagem e Performance

| Requisito (PDF § 3.2) | Onde |
|---|---|
| Schema + hypertable (chunk de 1 dia, justificado) | `init/timescaledb/01_schema.sql` · [REPORT](desafio-1/REPORT.md) |
| 10M em 12 meses, distribuição realista | `desafio-1/seed/` |
| CAggs: volume/hora e P95/P99 por instituição/dia | `init/timescaledb/04_caggs_policies.sql` |
| Retenção (90d raw / 2 anos CAgg) e compressão 7d | idem · REPORT § Retenção |
| Q1–Q4 com `EXPLAIN ANALYZE` antes/depois | `desafio-1/queries/` · `queries/explains/` |
| `time_bucket_gapfill` + `locf` (48h) | `desafio-1/queries/bonus_gapfill_48h.sql` |
| Sanitização LGPD de chunks comprimidos | `desafio-1/lgpd-sanitization.md` |
| Legado: schema, 2 queries otimizadas, bloat | `init/postgres-legado/` · `queries/legacy_q*.sql` |
| Análise PostgreSQL → Aurora | `desafio-1/migration-analysis.md` |
| ClickHouse: engine, `ORDER BY`, `PARTITION BY`, codecs | `init/clickhouse/01_schema.sql` |
| 2 MVs pré-agregadas + Dictionary | idem · REPORT § Dictionary vs JOIN |
| Query Grafana Pix 24h vs D-1, sub-segundo | `queries/grafana_pix_24h_vs_d1.sql` — **7 ms** |
| ClickHouse servindo aplicação | `desafio-2/pipeline/api/` |

### Desafio 2 — Pipeline e Arquitetura

| Requisito (PDF § 4.2) | Onde |
|---|---|
| Pipeline TimescaleDB → ClickHouse | `desafio-2/pipeline/sync-worker/` |
| Idempotência, retry, DLQ, observabilidade | idem · `metrics.py` |
| Mutação `pending → settled` demonstrada | `desafio-2/demo-sync-worker.sh` |
| Pipeline de referência (legado → Dictionary) | `desafio-2/pipeline/ref-sync/` |
| Diagramas (componentes, AWS, SLAs, falhas) | `desafio-2/diagrams/` (3 `.mmd`) |
| ADR com as 4 perguntas + SLOs | [desafio-2/ADR.md](desafio-2/ADR.md) |

> **Por que micro-batch e não CDC:** o Debezium foi construído, medido e
> descartado — `publish_via_partition_root` não funciona sobre hypertable
> (`relkind='r'`, chunk com `relispartition='f'`). Causa provada isolando a
> decodificação lógica: `pg_logical_slot_peek` → **0 mudanças**; após adicionar
> o chunk explicitamente → **6 na hora**. Rastrear 338 chunks não é operável. O
> experimento ficou sob o profile `cdc-experimento`.

### Desafio 3 — Operação e Resiliência

| Requisito (PDF § 5.2) | Onde |
|---|---|
| Backup dos 3 bancos (pgBackRest → MinIO) | `desafio-3/backup/` |
| Recovery drill com RTO/RPO medidos | `desafio-3/backup/restore-drill.sh` — **RTO 22 s** |
| Runbook: storage em 92% | `desafio-3/runbook.md` |
| 4 dashboards Grafana | `init/grafana/dashboards/` |
| 6 alertas com CloudWatch/SNS | `desafio-3/grafana/alertas.md` |
| Incidente SEV-1 (7 hipóteses) | `desafio-3/incident-response.md` |

---

## Serviços

| Serviço | Porta | Descrição |
|---|---|---|
| TimescaleDB | `5432` | Transacional (hypertable, CAggs, compressão) |
| PostgreSQL Legado | `5433` | Legado — candidato a Aurora; fonte do Dictionary |
| ClickHouse | `8123` / `9000` | Motor analítico — aplicações e Data Champions |
| **API** | `8000` | FastAPI servindo o ClickHouse (JSON) |
| **sync-worker** | `8001` | Pipeline TimescaleDB → ClickHouse (métricas Prometheus) |
| **ref-sync** | `8002` | Legado → Dictionary, batch de 5 min |
| Grafana | `3000` | 4 dashboards (admin/admin) |
| Prometheus | `9090` | Coleta + 6 regras de alerta |
| MinIO | `9002` / `9001` | Destino S3-compatível dos backups |

> MinIO publica na **9002**, não 9000: a 9000 é a porta nativa do ClickHouse.

---

## Demonstrações

```bash
# Pipeline: INSERT → pending → UPDATE → settled, com idempotência
bash desafio-2/demo-sync-worker.sh

# Detecção de duplicata (a Q4 retorna 0 no dataset — aqui o cenário é plantado)
bash desafio-1/scripts/q4-cenario-demo.sh

# Retenção: prova a política sem destruir dado (chunks sintéticos em 2020)
bash desafio-1/scripts/retention-demo.sh

# LGPD: anonimização sobre conta sintética, com auditoria
bash desafio-1/scripts/lgpd-erasure-demo.sh

# Recovery: perda simulada + restore em instância paralela (porta 5499)
bash desafio-3/backup/restore-drill.sh
```

Todos limpam o que criam e conferem as contagens ao final.

### Alta disponibilidade (fora do `up` padrão)

O risco nº 1 do sumário executivo — ClickHouse em nó único — tem resposta
executável, não só plano:

```bash
docker compose -f docker-compose.yml -f docker-compose.ha.yml up -d
bash scripts/tests/ha-smoke.sh
```

3 Keepers em quórum + 2 réplicas. O teste verifica topologia, DDL `ON CLUSTER`,
replicação bidirecional e **failover real** — derruba uma réplica, prova que
leitura e escrita continuam, e que o nó que volta se recupera sozinho.
**Resultado medido: 11 verificações, 0 falhas.**

Fica fora do `up` padrão de propósito: o critério de aceite nº 1 do PDF é o
ambiente subir com um comando, e cada peça a mais é uma chance a mais de falhar.

A decisão completa — por que nó único, o que ele custa em minutos de
indisponibilidade, a sequência de migração e as três armadilhas do Keeper que só
apareceram montando — está em [`docs/HA-CLICKHOUSE.md`](docs/HA-CLICKHOUSE.md).
O custo em dólar de promover isso a padrão está em
[`docs/CUSTO-AWS.md`](docs/CUSTO-AWS.md).

---

## Testes

```bash
bash scripts/tests/run_all.sh   # 171 testes de regressão do produto
bash scripts/tests/ha-smoke.sh  # 11 verificações do modo HA (exige o compose HA)
```

`SKIP` indica pré-condição ausente no ambiente (ex.: `make` não instalado neste
Windows), **não** falha.

---

## Três coisas que a medição contrariou

O que mais define esta entrega não são os números bons — é o que aconteceu
quando a medição discordou da expectativa. Os três estão documentados com o
número original:

| O que se esperava | O que foi medido | Onde |
|---|---|---|
| Índice parcial + covering aceleraria a Q2 | **1.584 → 1.511 ms — dentro do ruído.** O gargalo é o join com `transactions`, não o lado indexado. Acelerar o lado pequeno de um join não muda o custo do lado grande | [REPORT](desafio-1/REPORT.md) § O índice que não melhorou |
| Compressão de 10–20× | **5,0× no total** (23,5× só na tabela). Os 4 índices ocupam 1.484 MB contra 1.188 MB de dado — as duas otimizações do desafio se pagam uma contra a outra | REPORT § Compressão |
| P95 de 15h seria artefato do gerador sintético | **Era bug de modelagem.** A view agrupava sem `type`, misturando Pix (3 s) com boleto (47 h) no mesmo `percentile_cont`. Corrigido: **56.176 s → 3,20 s** | REPORT § O bug que este número escondia |

O terceiro é o mais relevante: **a primeira explicação era confortável e
errada.** "É artefato do dado sintético" encerraria o assunto. Investigar em vez
de aceitar trocou uma desculpa por uma correção de 17.555×.

---

## Estrutura

```
trio-data-challenge/
├── docker-compose.yml       ← ambiente principal (13 serviços)
├── docker-compose.ha.yml    ← modo HA: 3 Keepers + 2 réplicas
├── init/                    ← schema e config dos 3 bancos + Grafana/Prometheus
│   └── keeper/              ← configuração do quórum e das macros por réplica
├── desafio-1/               ← schemas, seed, queries, REPORT, migração, LGPD
├── desafio-2/               ← pipeline (sync-worker, ref-sync, api), diagramas, ADR
├── desafio-3/               ← backup, grafana (alertas), runbook, incidente
├── scripts/                 ← testes, health-check, backfill, saturação
└── docs/                    ← os documentos de leitura
```
