"""metrics.py — métricas Prometheus do sync-worker em :8001/metrics.

sync_last_success_timestamp é a mais importante do conjunto: é ela que detecta o
incidente SEV-1 do Desafio 3 (pipeline parado, dashboard zerado) em minutos. Um
contador de eventos não serve para isso — ele simplesmente para de crescer, e
"não cresceu" é indistinguível de "não houve movimento". Um timestamp que
envelhece é afirmativo.
"""
import time

from prometheus_client import Counter, Gauge, Histogram, start_http_server

# Prefixo sync_ (não pipeline_): identifica este worker sem ambiguidade agora que
# o consumidor CDC saiu do caminho principal e virou artefato de decisão.
rows_read_total = Counter(
    "sync_rows_read_total", "Linhas lidas da origem (TimescaleDB)"
)
rows_written_total = Counter(
    "sync_rows_written_total", "Linhas gravadas no ClickHouse"
)
errors_total = Counter(
    "sync_errors_total", "Erros por categoria", ["type"]
)
dlq_total = Counter(
    "sync_dlq_total", "Linhas descartadas para a dead-letter queue"
)
cycles_total = Counter(
    "sync_cycles_total", "Ciclos concluídos, por tipo", ["kind"]
)
lag_seconds = Gauge(
    "sync_lag_seconds", "now() - maior updated_at já sincronizado"
)
watermark_timestamp = Gauge(
    "sync_watermark_timestamp", "Epoch do watermark atual"
)
last_success_timestamp = Gauge(
    "sync_last_success_timestamp", "Epoch do último ciclo bem-sucedido"
)
batch_size = Histogram(
    "sync_batch_size", "Linhas por ciclo", buckets=(1, 10, 100, 1000, 10000, 50000)
)
cycle_duration_seconds = Histogram(
    "sync_cycle_duration_seconds", "Duração total do ciclo (leitura + escrita)"
)
read_duration_seconds = Histogram(
    "sync_read_duration_seconds", "Duração da consulta na origem"
)
write_duration_seconds = Histogram(
    "sync_write_duration_seconds", "Duração da escrita no ClickHouse"
)


def start(port: int):
    start_http_server(port)


def record_cycle(kind, n_rows, read_seconds, write_seconds, watermark_epoch, lag):
    """Um ciclo bem-sucedido. `kind` distingue o ciclo incremental da varredura
    completa — a diária é naturalmente mais lenta, e misturar as duas na mesma
    série tornaria o histograma de duração ilegível."""
    cycles_total.labels(kind=kind).inc()
    rows_written_total.inc(n_rows)
    batch_size.observe(n_rows)
    read_duration_seconds.observe(read_seconds)
    write_duration_seconds.observe(write_seconds)
    cycle_duration_seconds.observe(read_seconds + write_seconds)
    last_success_timestamp.set(time.time())
    if watermark_epoch is not None:
        watermark_timestamp.set(watermark_epoch)
    if lag is not None:
        lag_seconds.set(lag)


def record_read(n_rows: int):
    rows_read_total.inc(n_rows)


def record_error(error_type: str):
    errors_total.labels(type=error_type).inc()


def record_dlq(n: int = 1):
    dlq_total.inc(n)
