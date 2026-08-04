"""source.py — leitura da janela incremental no TimescaleDB e persistência do
watermark. É aqui que mora a decisão de performance mais importante do worker.

Substitui o transform.py do consumidor CDC: como a linha vem do psycopg já
tipada, não há envelope Debezium para desempacotar nem decimal em base64 para
converter — some a maior fonte de erro de forma do desenho anterior.
"""
import json
import logging
from datetime import datetime, timedelta, timezone

import psycopg
from psycopg.rows import dict_row

from config import Config

logger = logging.getLogger("source")

# Ordem exata do INSERT em transactions_raw (init/clickhouse/01_schema.sql).
# settlement_seconds fica de fora: é MATERIALIZED, o ClickHouse calcula sozinho.
COLUMNS = (
    "external_id", "tx_id", "created_at", "settled_at", "type", "status",
    "amount", "currency", "source_institution", "destination_institution",
    "source_account_id", "destination_account_id", "metadata",
    "_version", "_is_deleted", "_ingested_at",
)

# O predicado em created_at NÃO é redundante com o de updated_at.
#
# A hypertable é particionada por created_at. Um filtro só em updated_at não dá
# ao planner como descartar chunk nenhum — o plano mostra "Chunks excluded
# during startup: 0" e ele abre os 338. Medido em PREMISSAS-VERIFICADAS.md § P2b:
#
#     só updated_at            -> Seq Scan + Sort, 85.587 buffers
#     updated_at + created_at  -> Index Scan + Merge Append, 17 buffers  (~5.000x)
#
# O ORDER BY casa com idx_tx_updated_at (updated_at, id), então o Merge Append
# devolve já ordenado e o Sort desaparece do plano.
_SELECT_INCREMENTAL = """
    SELECT id, external_id, amount, currency, status::text AS status,
           type::text AS type, source_institution, destination_institution,
           source_account_id, destination_account_id,
           created_at, settled_at, updated_at, metadata
      FROM transactions
     WHERE updated_at >= %(watermark)s
       AND created_at >= %(created_floor)s
     ORDER BY updated_at, id
     LIMIT %(limit)s
"""

# Varredura completa: mesma projeção, sem o corte de created_at. Existe para
# capturar UPDATE em transação mais antiga que a janela (estorno tardio,
# reconciliação retroativa) — o preço é varrer todos os chunks, por isso roda
# a cada FULL_SCAN_INTERVAL_HOURS e não a cada ciclo.
_SELECT_FULL = """
    SELECT id, external_id, amount, currency, status::text AS status,
           type::text AS type, source_institution, destination_institution,
           source_account_id, destination_account_id,
           created_at, settled_at, updated_at, metadata
      FROM transactions
     WHERE updated_at >= %(watermark)s
     ORDER BY updated_at, id
     LIMIT %(limit)s
"""


def connect():
    return psycopg.connect(
        host=Config.PG_HOST, port=Config.PG_PORT, user=Config.PG_USER,
        password=Config.PG_PASSWORD, dbname=Config.PG_DATABASE,
        row_factory=dict_row, autocommit=True,
    )


def read_state(conn) -> dict:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT last_updated_at, last_full_scan_at, rows_synced "
            "FROM sync_state WHERE source = %s", (Config.SYNC_SOURCE,))
        row = cur.fetchone()
    if row is None:
        raise RuntimeError(
            f"sync_state sem linha para '{Config.SYNC_SOURCE}' — "
            "init/timescaledb/06_sync_state.sql não foi aplicado")
    return row


def should_full_scan(state: dict) -> bool:
    last = state.get("last_full_scan_at")
    if last is None:
        return True
    idade = datetime.now(timezone.utc) - last
    return idade >= timedelta(hours=Config.FULL_SCAN_INTERVAL_HOURS)


def fetch_window(conn, watermark: datetime, full: bool) -> list[dict]:
    """Lê a janela a partir do watermark (já com o overlap aplicado pelo
    chamador). Devolve as linhas na ordem (updated_at, id) — determinística,
    o que permite retomar exatamente de onde parou."""
    params = {"watermark": watermark, "limit": Config.BATCH_MAX_ROWS}
    if full:
        sql = _SELECT_FULL
    else:
        sql = _SELECT_INCREMENTAL
        params["created_floor"] = watermark - timedelta(days=Config.CREATED_AT_WINDOW_DAYS)
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def _metadata_json(value) -> str:
    if value is None:
        return "{}"
    return value if isinstance(value, str) else json.dumps(value, separators=(",", ":"))


def to_clickhouse_row(row: dict) -> dict:
    """Linha do Postgres -> linha do ClickHouse.

    _version = updated_at em milissegundos. É o critério de desempate do
    ReplacingMergeTree: entre duas versões da mesma transação, sobrevive a de
    maior _version. Usar o relógio da origem (e não o de chegada) mantém a
    ordem correta mesmo se um ciclo atrasar e escrever fora de ordem.
    """
    return {
        "external_id": str(row["external_id"]),
        "tx_id": int(row["id"]),
        "created_at": row["created_at"],
        "settled_at": row["settled_at"],
        "type": row["type"],
        "status": row["status"],
        "amount": str(row["amount"]),
        "currency": row["currency"],
        "source_institution": row["source_institution"],
        "destination_institution": row["destination_institution"],
        "source_account_id": row["source_account_id"] or 0,
        "destination_account_id": row["destination_account_id"] or 0,
        # metadata é jsonb na origem e String no ClickHouse: o psycopg já
        # desserializa em dict, então serializa de volta na escrita.
        "metadata": _metadata_json(row["metadata"]),
        "_version": int(row["updated_at"].timestamp() * 1000),
        # Watermark não captura DELETE físico: a linha some da origem sem deixar
        # rastro em updated_at. Trade-off aceito e declarado no ADR — em domínio
        # financeiro transação não se apaga, se estorna (status='reversed'), e o
        # DELETE administrativo é trilha LGPD separada.
        "_is_deleted": 0,
        "_ingested_at": datetime.now(timezone.utc),
    }


def commit_watermark(conn, new_watermark: datetime, n_rows: int, full: bool):
    """Avança o watermark. Chamado SÓ depois de o ClickHouse confirmar a escrita.

    Essa ordem é o que garante a corretude do pipeline: se o processo morrer
    entre a escrita e este UPDATE, o watermark antigo faz o próximo ciclo reler
    a janela — e a releitura é absorvida pelo ReplacingMergeTree. O inverso
    (avançar antes de escrever) perderia linhas silenciosamente.
    """
    sets = ["last_updated_at = %(wm)s", "last_run_at = now()",
            "rows_synced = rows_synced + %(n)s"]
    if full:
        sets.append("last_full_scan_at = now()")
    with conn.cursor() as cur:
        cur.execute(
            f"UPDATE sync_state SET {', '.join(sets)} WHERE source = %(src)s",
            {"wm": new_watermark, "n": n_rows, "src": Config.SYNC_SOURCE})


def touch_full_scan(conn):
    """Marca a varredura completa como feita mesmo quando ela não trouxe linha
    nenhuma — sem isso, um full scan vazio seria repetido a cada ciclo."""
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE sync_state SET last_full_scan_at = now() WHERE source = %s",
            (Config.SYNC_SOURCE,))
