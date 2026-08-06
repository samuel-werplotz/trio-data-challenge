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
# Frescor: idade do DADO de referência — segundos desde o max(updated_at) do
# legado. Entre mudanças ela cresce sozinha, e isso é correto: mede a idade do
# dado, não a do ciclo. Serve ao painel ("o cadastro que a API lê está velho?").
#
# NÃO serve de alerta: num legado estático ela cresce indefinidamente com o
# worker perfeitamente saudável — falso positivo permanente. Pior, se o
# ref-sync MORRER a série congela em vez de crescer, então ela dispara igual no
# caso bom e no ruim, e não distingue nada. Quem alerta é a série abaixo.
dictionary_age_seconds = Gauge(
    "refsync_dictionary_age_seconds",
    "Segundos desde o max(updated_at) do legado já refletido no Dictionary",
)
# Idade da última VERIFICAÇÃO bem-sucedida — o par de
# sync_last_success_timestamp do pipeline principal. É esta que o alerta usa:
# ela cresce quando o worker para de checar, que é o risco real.
check_age_seconds = Gauge(
    "refsync_check_age_seconds",
    "Segundos desde o último ciclo concluído com sucesso (com ou sem reload)",
)
source_rows = Gauge(
    "refsync_source_rows", "Linhas na tabela de origem do legado"
)
cycle_duration_seconds = Histogram(
    "refsync_cycle_duration_seconds", "Duração do ciclo"
)

# Epoch do último ciclo OK, em lista de um elemento para a closure de
# set_function poder ler o valor corrente sem `global`. Começa em 0.0: antes do
# primeiro ciclo não há "última verificação", e check_age_seconds reporta 0 em
# vez de um número gigante que dispararia alerta durante a subida.
_last_ok = [0.0]


def start(port: int):
    start_http_server(port)


# check_age_seconds precisa envelhecer ENTRE os ciclos, não só quando um roda —
# o laço é de 5 min, e uma gauge escrita apenas no ciclo ficaria congelada no
# intervalo (e, se o worker morresse, congelaria para sempre no último valor).
# set_function é avaliada a cada scrape do Prometheus, então a série cresce
# sozinha e o alerta dispara mesmo com o processo parado.
check_age_seconds.set_function(
    lambda: (time.time() - _last_ok[0]) if _last_ok[0] else 0.0
)


def record_cycle(outcome: str, duration: float, age: float | None, rows: int | None):
    """Um ciclo concluído. `outcome` separa 'reloaded' de 'unchanged' — a maioria
    esmagadora dos ciclos não muda nada (é o ponto da decisão de batch), e
    misturar os dois esconderia quando uma recarga de fato aconteceu."""
    cycles_total.labels(outcome=outcome).inc()
    cycle_duration_seconds.observe(duration)
    now = time.time()
    last_success_timestamp.set(now)
    # Marca a verificação como feita AGORA, tenha havido reload ou não — é a
    # diferença entre "o worker está checando" e "o dado mudou".
    _last_ok[0] = now
    if age is not None:
        dictionary_age_seconds.set(age)
    if rows is not None:
        source_rows.set(rows)


def record_reload():
    reloads_total.inc()
    last_reload_timestamp.set(time.time())


def record_error(error_type: str):
    errors_total.labels(type=error_type).inc()
