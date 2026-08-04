"""main.py — laço principal do consumidor CDC (S05 § O laço principal).
Redpanda (tópico trio.public.transactions) -> transform -> micro-batch ->
ClickHouse. Falha de dado vai para a DLQ e o consumo continua; falha de
infraestrutura tenta de novo e, se persistir, PARA o consumo sem perder
offset (não descarta o lote — é a diferença entre indisponibilidade
temporária e corrupção de dado).
"""
import logging
import sys
import time

from confluent_kafka import Consumer, KafkaError, Producer

import metrics
import sink
from config import Config
from transform import TransformError, transform

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("main")


def make_consumer() -> Consumer:
    return Consumer({
        "bootstrap.servers": Config.KAFKA_BOOTSTRAP,
        "group.id": Config.KAFKA_GROUP_ID,
        "auto.offset.reset": "earliest",
        "enable.auto.commit": False,  # commit manual, só depois da escrita confirmada
    })


def make_dlq_producer() -> Producer:
    return Producer({"bootstrap.servers": Config.KAFKA_BOOTSTRAP})


def send_to_dlq(producer: Producer, raw_value: bytes, reason: str):
    """DLQ imediata para evento malformado — retentar o mesmo erro 5x só
    desperdiça tempo (S05 § Distinção importante: falha de dado != falha de infra)."""
    headers = [("dlq_reason", reason.encode("utf-8")[:1000])]
    producer.produce(Config.KAFKA_DLQ_TOPIC, value=raw_value, headers=headers)
    producer.poll(0)
    metrics.record_dlq()
    metrics.record_error("dlq")


def compute_lag(rows: list[dict]) -> float | None:
    """now() - source.ts_ms do lote (aproximado pelo _ingested_at que acabamos
    de gerar contra o created_at mais recente do lote não seria correto —
    usa-se o _version/updated_at mais recente como proxy do 'agora' da origem)."""
    if not rows:
        return None
    try:
        newest_version_ms = max(r["_version"] for r in rows)
        return max(0.0, time.time() - newest_version_ms / 1000.0)
    except (KeyError, TypeError, ValueError):
        return None


def run():
    consumer = make_consumer()
    dlq_producer = make_dlq_producer()
    ch_client = sink.get_client()
    consumer.subscribe([Config.KAFKA_TOPIC])

    metrics.start(Config.METRICS_PORT)
    logger.info("consumidor iniciado — tópico=%s grupo=%s", Config.KAFKA_TOPIC, Config.KAFKA_GROUP_ID)

    buffer: list[dict] = []
    buffer_started_at = time.monotonic()

    try:
        while True:
            msgs = consumer.consume(num_messages=Config.BATCH_MAX_ROWS, timeout=Config.CONSUME_TIMEOUT_SECONDS)

            op_counts: dict[str, int] = {}
            for msg in msgs:
                if msg.error():
                    if msg.error().code() != KafkaError._PARTITION_EOF:
                        logger.error("erro do broker: %s", msg.error())
                        metrics.record_error("broker")
                    continue

                raw_value = msg.value()
                try:
                    row = transform(raw_value)
                    buffer.append(row)
                    op = row.get("_is_deleted") and "d" or "cu"
                    op_counts[op] = op_counts.get(op, 0) + 1
                except TransformError as exc:
                    logger.warning("evento malformado -> DLQ: %s", exc)
                    send_to_dlq(dlq_producer, raw_value, str(exc))
                except Exception as exc:  # noqa: BLE001 — rede de segurança final
                    # transform.py já cobre os casos previstos; isto pega o
                    # que passou batido (bug de transform, tipo inesperado
                    # não antecipado). 1 evento ruim não pode derrubar o
                    # laço inteiro — vai para a DLQ com o traceback.
                    logger.exception("erro inesperado na transformação -> DLQ")
                    send_to_dlq(dlq_producer, raw_value, f"erro inesperado: {exc}")

            elapsed = time.monotonic() - buffer_started_at
            should_flush = buffer and (
                len(buffer) >= Config.BATCH_MAX_ROWS or elapsed >= Config.BATCH_MAX_SECONDS
            )

            if should_flush:
                try:
                    write_seconds = sink.write_batch(ch_client, buffer)
                except sink.WriteFailedError as exc:
                    # infraestrutura fora mesmo após todo o retry: para o
                    # consumo SEM commitar — o lote não se perde, o
                    # reprocessamento pega exatamente daqui quando voltar.
                    logger.critical("escrita falhou após todas as tentativas — parando consumo: %s", exc)
                    metrics.record_error("write_exhausted")
                    break

                lag = compute_lag(buffer)
                metrics.record_batch(op_counts, len(buffer), write_seconds, lag)
                consumer.commit(asynchronous=False)
                logger.info("lote escrito: %d linhas em %.3fs (lag=%.1fs)", len(buffer), write_seconds, lag or -1)
                buffer = []
                buffer_started_at = time.monotonic()

    except KeyboardInterrupt:
        logger.info("encerrando por interrupção")
    finally:
        consumer.close()
        dlq_producer.flush()


if __name__ == "__main__":
    try:
        run()
    except Exception:
        logger.exception("consumidor encerrado por erro não tratado")
        sys.exit(1)
