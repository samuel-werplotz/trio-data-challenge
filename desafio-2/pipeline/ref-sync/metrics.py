"""metrics.py — métricas Prometheus do ref-sync em :8002/metrics.

O papel deste worker é estreito (forçar recarga e medir frescor), então a
métrica que importa é refsync_dictionary_age_seconds: quanto tempo faz que o
Dictionary do ClickHouse reflete o legado. É a série que responde "o dado de
referência que a API está lendo está velho?" — pergunta que nenhum contador de
ciclos responde.
"""
import time

from prometheus_client import Counter, Gauge, Histogram, start_http_server

cycles_total = Counter(
    "refsync_cycles_total", "Ciclos concluídos, por desfecho", ["outcome"]
)
reloads_total = Counter(
    "refsync_reloads_total", "SYSTEM RELOAD DICTIONARY disparados"
)
errors_total = Counter(
    "refsync_errors_total", "Erros por categoria", ["type"]
)
last_success_timestamp = Gauge(
    "refsync_last_success_timestamp", "Epoch do último ciclo bem-sucedido"
)
last_reload_timestamp = Gauge(
    "refsync_last_reload_timestamp", "Epoch da última recarga do Dictionary"
)
# Frescor: idade do dado de referência do ponto de vista de quem lê o
# Dictionary. Alimenta o painel e o alerta do Desafio 3.
dictionary_age_seconds = Gauge(
    "refsync_dictionary_age_seconds",
    "Segundos desde o max(updated_at) do legado já refletido no Dictionary",
)
source_rows = Gauge(
    "refsync_source_rows", "Linhas na tabela de origem do legado"
)
cycle_duration_seconds = Histogram(
    "refsync_cycle_duration_seconds", "Duração do ciclo"
)


def start(port: int):
    start_http_server(port)


def record_cycle(outcome: str, duration: float, age: float | None, rows: int | None):
    """Um ciclo concluído. `outcome` separa 'reloaded' de 'unchanged' — a maioria
    esmagadora dos ciclos não muda nada (é o ponto da decisão de batch), e
    misturar os dois esconderia quando uma recarga de fato aconteceu."""
    cycles_total.labels(outcome=outcome).inc()
    cycle_duration_seconds.observe(duration)
    last_success_timestamp.set(time.time())
    if age is not None:
        dictionary_age_seconds.set(age)
    if rows is not None:
        source_rows.set(rows)


def record_reload():
    reloads_total.inc()
    last_reload_timestamp.set(time.time())


def record_error(error_type: str):
    errors_total.labels(type=error_type).inc()
