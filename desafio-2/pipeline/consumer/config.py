"""config.py — configuração do consumidor via variáveis de ambiente (S05).
Nenhum valor sensível hardcoded; defaults só para o ambiente local do desafio.
"""
import os


class Config:
    # Redpanda / Kafka
    KAFKA_BOOTSTRAP = os.environ.get("KAFKA_BOOTSTRAP", "redpanda:9092")
    KAFKA_TOPIC = os.environ.get("KAFKA_TOPIC", "trio.public.transactions")
    KAFKA_GROUP_ID = os.environ.get("KAFKA_GROUP_ID", "trio-cdc-consumer")
    KAFKA_DLQ_TOPIC = os.environ.get("KAFKA_DLQ_TOPIC", "trio.dlq.transactions")

    # ClickHouse
    CLICKHOUSE_HOST = os.environ.get("CLICKHOUSE_HOST", "clickhouse")
    CLICKHOUSE_PORT = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
    CLICKHOUSE_USER = os.environ.get("CLICKHOUSE_USER", "trio")
    CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "trio2024")
    CLICKHOUSE_DATABASE = os.environ.get("CLICKHOUSE_DATABASE", "trio_analytics")
    CLICKHOUSE_TABLE = os.environ.get("CLICKHOUSE_TABLE", "transactions_raw")

    # Micro-batch (S05 § Micro-batch): equilibra latência e número de partes.
    BATCH_MAX_ROWS = int(os.environ.get("BATCH_MAX_ROWS", "5000"))
    BATCH_MAX_SECONDS = float(os.environ.get("BATCH_MAX_SECONDS", "2"))
    CONSUME_TIMEOUT_SECONDS = float(os.environ.get("CONSUME_TIMEOUT_SECONDS", "2"))

    # Retry exponencial (S05 § Tratamento de falhas): 1,2,4,8,16s, depois para.
    RETRY_DELAYS_SECONDS = [1, 2, 4, 8, 16]

    METRICS_PORT = int(os.environ.get("METRICS_PORT", "8001"))
