"""sink.py — escreve um lote de linhas transformadas em transactions_raw,
com retry exponencial (S05 § Tratamento de falhas). Falha de infraestrutura
(ClickHouse fora) tenta de novo porque vai voltar; falha de dado já foi
filtrada antes de chegar aqui (isso é trabalho do transform.py + DLQ).
"""
import logging
import time

import clickhouse_connect

from config import Config
from transform import COLUMNS

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
    """Escreve o lote com retry 1,2,4,8,16s. Retorna a duração da escrita
    bem-sucedida em segundos. Levanta WriteFailedError após esgotar as tentativas
    — não descarta o lote, quem chama decide parar o consumo (S05: 'após 5
    tentativas, para o consumo, não descarta')."""
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

    raise WriteFailedError(f"esgotadas {len(Config.RETRY_DELAYS_SECONDS)} tentativas: {last_exc}")
