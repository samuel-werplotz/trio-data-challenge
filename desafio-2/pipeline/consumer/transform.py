"""transform.py — converte 1 evento Debezium (envelope JSON do pgoutput) em
1 linha pronta para o INSERT no ClickHouse (S05 § Transformação do evento).
Levanta TransformError para tudo que deve ir para a DLQ em vez de derrubar
o consumidor — é a fronteira entre "falha de dado" (DLQ) e "falha de
infraestrutura" (retry), que vive em sink.py.
"""
import json
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation


class TransformError(Exception):
    """Evento que não pode virar linha válida — vai para a DLQ, não se reprocessa."""


# Colunas na ordem exata do INSERT em transactions_raw (init/clickhouse/01_schema.sql).
# settlement_seconds é MATERIALIZED — não é inserida, o ClickHouse calcula sozinho.
COLUMNS = (
    "external_id", "tx_id", "created_at", "settled_at", "type", "status",
    "amount", "currency", "source_institution", "destination_institution",
    "source_account_id", "destination_account_id", "metadata",
    "_version", "_is_deleted", "_ingested_at",
)


def _parse_iso_ts(value):
    """created_at/settled_at/updated_at chegam como string ISO 8601 (Z=UTC)."""
    if value is None:
        return None
    # Debezium emite frações de segundo com precisão variável (adaptive_time_microseconds);
    # normaliza 'Z' para offset explícito, que datetime.fromisoformat aceita.
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def transform(raw_message: bytes) -> dict:
    """Evento Debezium bruto -> dict pronto para o INSERT em lote.
    Qualquer falha de forma (tipo errado, campo faltando) vira TransformError
    -> DLQ. Deixar uma AttributeError/KeyError vazar daqui derrubaria o
    consumidor inteiro por 1 evento malformado — exatamente o que a DLQ
    existe para evitar (S05 § Distinção importante)."""
    try:
        envelope = json.loads(raw_message)
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise TransformError(f"JSON inválido: {exc}") from exc

    if not isinstance(envelope, dict):
        raise TransformError(f"envelope não é um objeto JSON: {type(envelope).__name__}")

    payload = envelope.get("payload")
    if not isinstance(payload, dict):
        raise TransformError(f"'payload' ausente ou não é objeto: {type(payload).__name__}")

    op = payload.get("op")
    if op is None:
        raise TransformError("payload sem campo 'op'")

    # op='d' (delete): os dados vêm de 'before', não de 'after' — o after de
    # um delete é null (S05 § Transformação do evento).
    source_row = payload.get("before") if op == "d" else payload.get("after")
    if source_row is None:
        raise TransformError(f"op='{op}' sem linha correspondente (before/after ausente)")

    try:
        amount = Decimal(source_row["amount"])
    except (InvalidOperation, KeyError, TypeError) as exc:
        raise TransformError(f"amount inválido: {source_row.get('amount')!r} ({exc})") from exc

    try:
        created_at = _parse_iso_ts(source_row["created_at"])
        settled_at = _parse_iso_ts(source_row.get("settled_at"))
    except (ValueError, KeyError) as exc:
        raise TransformError(f"timestamp inválido: {exc}") from exc

    # _version = updated_at em ms — reflete a ordem real da origem, mesmo se
    # o evento chegar fora de ordem pela rede (S05 § _version).
    updated_at_raw = source_row.get("updated_at")
    if updated_at_raw:
        version = int(_parse_iso_ts(updated_at_raw).timestamp() * 1000)
    else:
        # fallback defensivo: updated_at não deveria faltar, mas se faltar,
        # usa o timestamp do próprio evento Debezium (source.ts_ms).
        source_meta = payload.get("source", {})
        ts_ms = source_meta.get("ts_ms")
        if ts_ms is None:
            raise TransformError("updated_at e source.ts_ms ausentes — sem versão possível")
        version = int(ts_ms)

    try:
        tx_id = int(source_row["id"])
    except (KeyError, TypeError, ValueError) as exc:
        raise TransformError(f"id (tx_id) inválido: {exc}") from exc

    return {
        "external_id": source_row["external_id"],
        "tx_id": tx_id,
        # clickhouse_connect serializa datetime.datetime nativamente para
        # DateTime64 — passar string aqui quebra a escrita binária.
        "created_at": created_at,
        "settled_at": settled_at,
        "type": source_row["type"],
        "status": source_row["status"],
        "amount": str(amount),
        "currency": source_row.get("currency", "BRL"),
        "source_institution": source_row["source_institution"],
        "destination_institution": source_row["destination_institution"],
        "source_account_id": source_row.get("source_account_id") or 0,
        "destination_account_id": source_row.get("destination_account_id") or 0,
        "metadata": source_row.get("metadata") or "{}",
        "_version": version,
        "_is_deleted": 1 if op == "d" else 0,
        "_ingested_at": datetime.now(timezone.utc),
    }
