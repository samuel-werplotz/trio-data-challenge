"""sink.py — escreve um lote de linhas em transactions_raw, com retry
exponencial (1,2,4,8,16s).

Reaproveitado do consumidor CDC (desafio-2/pipeline/consumer/sink.py) mudando
uma linha: de onde vem COLUMNS. A política de retry não depende de a origem ser
um tópico Kafka ou uma janela de SELECT — só de o destino poder estar fora.

Distinção que o módulo preserva: falha de INFRAESTRUTURA (ClickHouse indisponível)
tenta de novo, porque vai voltar. Falha de DADO já foi filtrada antes de chegar
aqui. Esgotadas as tentativas, o lote NÃO é descartado: quem chama decide, e no
sync-worker a decisão é não avançar o watermark — o ciclo seguinte relê a janela.
"""
import logging
import time

import clickhouse_connect

from config import Config
from source import COLUMNS

logger = logging.getLogger("sink")


class WriteFailedError(Exception):
    """Todas as tentativas de retry se esgotaram — o chamador decide parar o consumo."""


def get_client():
    return clickhouse_connect.get_client(
        host=Config.CLICKHOUSE_HOST,
        port=Config.CLICKHOUSE_PORT,
        username=Config.CLICKHOUSE_USER,
        password=Config.CLICKHOUSE_PASSWORD,
        database=Config.CLICKHOUSE_DATABASE,
    )


def write_batch(client, rows: list[dict]) -> float:
    """Escreve o lote: 1 tentativa imediata + retries em 1,2,4,8,16s.
    Retorna a duração da escrita bem-sucedida. Esgotadas as tentativas, levanta
    WriteFailedError sem descartar o lote — quem chama decide o que fazer."""
    data = [[row[col] for col in COLUMNS] for row in rows]

    last_exc = None
    for attempt, delay in enumerate([0] + Config.RETRY_DELAYS_SECONDS):
        if delay:
            logger.warning("retry em %ss (tentativa %d)", delay, attempt)
            time.sleep(delay)
        try:
            t0 = time.monotonic()
            client.insert(Config.CLICKHOUSE_TABLE, data, column_names=list(COLUMNS))
            return time.monotonic() - t0
        except Exception as exc:  # ClickHouse indisponível, timeout, etc.
            last_exc = exc
            logger.error("falha ao escrever lote (tentativa %d): %s", attempt + 1, exc)

    # +1: a primeira passada do laço é a tentativa imediata (delay=0), não um retry.
    total = len(Config.RETRY_DELAYS_SECONDS) + 1
    raise WriteFailedError(f"esgotadas {total} tentativas: {last_exc}")
