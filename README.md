# Trio Data Challenge — Engenheiro de Dados Sênior

Ambiente base para o desafio técnico da Trio Grupo Financeiro.

## Quick Start

```bash
cp .env.example .env
docker-compose up -d
```

## Serviços

| Serviço | Porta | Descrição |
|---------|-------|-----------|
| TimescaleDB | `5432` | Banco transacional principal |
| PostgreSQL Legado | `5433` | Legado transacional (candidato a Aurora/RDS) |
| ClickHouse (HTTP) | `8123` | Motor de dados — aplicações e consultas |
| ClickHouse (Native) | `9000` | Protocolo nativo |
| Grafana | `3000` | Dashboards (admin/admin) |

## Conexões

```bash
# TimescaleDB
psql -h localhost -p 5432 -U trio -d trio_transactions

# PostgreSQL Legado
psql -h localhost -p 5433 -U trio -d trio_legado

# ClickHouse (CLI)
clickhouse-client --host localhost --port 9000 --user trio --password trio2024 --database trio_analytics

# ClickHouse (HTTP)
curl "http://localhost:8123/?user=trio&password=trio2024&database=trio_analytics" --data "SELECT 1"

# Grafana
# http://localhost:3000 — Datasources já pré-configurados
```

## Estrutura

```
trio-data-challenge/
├── docker-compose.yml
├── .env.example
├── init/
│   ├── timescaledb/        ← Scripts de init do banco transacional
│   ├── postgres-legado/    ← Scripts de init do legado
│   ├── clickhouse/         ← Scripts de init do motor analítico
│   └── grafana/
│       └── provisioning/   ← Datasources pré-configurados
└── README.md
```

## Notas

- Evolua este `docker-compose.yml` conforme necessário.
- Adicione serviços extras (Kafka, Debezium, scripts, etc) se julgar relevante.
- Os diretórios `init/` contêm scripts de inicialização que rodam na criação dos containers.
- O Grafana já vem com datasources configurados para os três bancos.
