"""metrics.py — métricas Prometheus expostas em :8001/metrics (S05).
pipeline_last_success_timestamp é a mais importante: é ela que detectaria
o incidente SEV-1 (pipeline parado) em minutos, não a contagem de eventos.
"""
import time

from prometheus_client import Counter, Gauge, Histogram, start_http_server

events_total = Counter(
    "pipeline_events_total", "Eventos CDC recebidos, por tipo de operação", ["op"]
)
rows_written_total = Counter(
    "pipeline_rows_written_total", "Linhas efetivamente gravadas no ClickHouse"
)
errors_total = Counter(
    "pipeline_errors_total", "Erros por categoria", ["type"]
)
dlq_total = Counter(
    "pipeline_dlq_total", "Eventos enviados para a dead-letter queue"
)
lag_seconds = Gauge(
    "pipeline_lag_seconds", "now() - source.ts_ms do último evento processado"
)
last_success_timestamp = Gauge(
    "pipeline_last_success_timestamp", "Epoch da última escrita bem-sucedida"
)
batch_size = Histogram(
    "pipeline_batch_size", "Tamanho dos lotes escritos", buckets=(1, 10, 100, 1000, 5000, 10000)
)
write_duration_seconds = Histogram(
    "pipeline_write_duration_seconds", "Duração da escrita em lote no ClickHouse"
)


def start(port: int):
    start_http_server(port)


def record_batch(op_counts: dict, n_rows: int, write_seconds: float, lag: float | None):
    for op, n in op_counts.items():
        events_total.labels(op=op).inc(n)
    rows_written_total.inc(n_rows)
    batch_size.observe(n_rows)
    write_duration_seconds.observe(write_seconds)
    last_success_timestamp.set(time.time())
    if lag is not None:
        lag_seconds.set(lag)


def record_error(error_type: str):
    errors_total.labels(type=error_type).inc()


def record_dlq():
    dlq_total.inc()
