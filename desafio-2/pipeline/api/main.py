"""main.py — API HTTP que serve o ClickHouse para aplicação.

Existe para atender um requisito explícito do desafio (PDF § 3.2 C.5): mostrar
o ClickHouse servindo APLICAÇÃO, não só dashboard. O endpoint mais defensável
do conjunto é /institutions/{code}/health — não é visualização, é decisão
automatizada: um serviço de roteamento consulta e para de mandar Pix para uma
instituição degradada.

Três endpoints de negócio (Container-API.md) + /health e /metrics operacionais.
Toda resposta de negócio carrega query_ms, que torna a latência observável pelo
cliente — e é o que evidencia o cache de 10s numa segunda chamada.
"""
import logging
import time
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Path, Query
from fastapi.responses import JSONResponse, PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

import db
from config import Config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger("api")

app = FastAPI(
    title="Trio Analytics API",
    description="ClickHouse servindo aplicação — operações, roteamento e antifraude.",
    version="1.0.0",
)

# --- Métricas -------------------------------------------------------------
# Separadas por endpoint: a latência de /fraud/duplicates (varre a raw) não tem
# nada a ver com a de /ops/volume-now (lê MV agregada), e a média das duas não
# descreveria nenhuma das duas.
requests_total = Counter(
    "api_requests_total", "Requisições por endpoint e desfecho", ["endpoint", "outcome"]
)
request_duration_seconds = Histogram(
    "api_request_duration_seconds", "Duração da requisição", ["endpoint"]
)
cache_hits_total = Counter(
    "api_cache_hits_total", "Respostas servidas do cache", ["endpoint"]
)
cache_misses_total = Counter(
    "api_cache_misses_total", "Respostas que foram ao ClickHouse", ["endpoint"]
)


def _served(endpoint: str, cache_key: tuple, build):
    """Fluxo comum dos endpoints de negócio: tenta o cache, senão consulta e
    guarda. Devolve o corpo já com query_ms e cached preenchidos.

    query_ms mede o caminho de fato percorrido: no acerto de cache é o custo de
    servir da memória (sub-milissegundo), no erro é a ida ao ClickHouse. É essa
    diferença que comprova o cache de 10s do lado do cliente.
    """
    started = time.perf_counter()

    cached = db.cache.get(cache_key)
    if cached is not None:
        elapsed_ms = round((time.perf_counter() - started) * 1000, 3)
        cache_hits_total.labels(endpoint=endpoint).inc()
        requests_total.labels(endpoint=endpoint, outcome="ok").inc()
        request_duration_seconds.labels(endpoint=endpoint).observe(
            time.perf_counter() - started
        )
        return {**cached, "query_ms": elapsed_ms, "cached": True}

    cache_misses_total.labels(endpoint=endpoint).inc()
    try:
        body = build()
    except HTTPException:
        # 404 de "instituição sem dados" é resposta de negócio, não falha de
        # infraestrutura: precisa passar intacto em vez de virar 503 abaixo.
        requests_total.labels(endpoint=endpoint, outcome="not_found").inc()
        raise
    except Exception as exc:  # noqa: BLE001 — vira 503 com a causa no log
        requests_total.labels(endpoint=endpoint, outcome="error").inc()
        logger.error("%s falhou: %s", endpoint, exc, exc_info=True)
        # 503 e não 500: a causa quase sempre é o ClickHouse indisponível ou a
        # query estourando o timeout — condição transitória, e o cliente pode
        # tentar de novo.
        raise HTTPException(status_code=503, detail=f"consulta indisponível: {exc}")

    db.cache.set(cache_key, body)
    elapsed_ms = round((time.perf_counter() - started) * 1000, 3)
    requests_total.labels(endpoint=endpoint, outcome="ok").inc()
    request_duration_seconds.labels(endpoint=endpoint).observe(
        time.perf_counter() - started
    )
    return {**body, "query_ms": elapsed_ms, "cached": False}


# --- 1. Volume agora ------------------------------------------------------
# Lê transactions_raw e não a MV: a MV agrega por hora, e uma janela de 5 min
# dentro da hora corrente não é derivável do bucket horário. O corte por
# created_at usa a chave de particionamento, então varre uma partição só.
_SQL_VOLUME_NOW = """
    SELECT type,
           count()      AS tx_count,
           sum(amount)  AS total_amount
      FROM transactions_raw
     WHERE created_at >= %(since)s
       AND _is_deleted = 0
     GROUP BY type
     ORDER BY tx_count DESC
"""


@app.get("/ops/volume-now")
def volume_now(minutes: int = Query(5, ge=1, le=60)):
    """Volume por tipo de transação na janela recente. Alimenta painel de operações."""
    def build():
        # O dataset do desafio é histórico: a última transação é de alguns
        # minutos/horas atrás, não de agora. Ancorar em now() devolveria vazio e
        # esconderia o funcionamento do endpoint, então a janela parte do
        # instante mais recente que existe no dado.
        rows, _ = db.query("SELECT max(created_at) FROM transactions_raw")
        anchor = rows[0][0] if rows and rows[0][0] else datetime.now(timezone.utc)
        since = anchor - _timedelta_minutes(minutes)

        rows, _ = db.query(_SQL_VOLUME_NOW, {"since": since})
        return {
            "window": f"{minutes}m",
            "anchor": anchor.isoformat(),
            "data": [
                {"type": r[0], "count": int(r[1]), "amount": float(r[2])} for r in rows
            ],
        }

    return _served("volume_now", ("volume_now", minutes), build)


def _timedelta_minutes(minutes: int):
    from datetime import timedelta

    return timedelta(minutes=minutes)


# --- 2. Saúde da instituição ---------------------------------------------
# Lê status_funnel (AggregatingMergeTree): a P95 de liquidação já está
# pré-agregada por hora, então a decisão de roteamento não paga o custo de
# varrer a raw. quantileMerge combina os estados das horas da janela.
#
# O nome do Dictionary entra na resposta via dictGetOrDefault — mesmo padrão
# documentado em S04. É o que liga o dado de referência (ref-sync) ao dado
# transacional na mesma resposta.
#
# O countMerge acontece na subconsulta e o sum() na externa. Empilhar os dois no
# mesmo nível (`sum(countMerge(cnt))`) é ILLEGAL_AGGREGATION — o ClickHouse não
# aceita função de agregação dentro de outra. A subconsulta agrupa pela chave
# real da tabela (hour, type, status) para desfazer os estados na granularidade
# em que foram gravados; as colunas de estado entram no GROUP BY porque são
# repassadas intactas para o merge da consulta externa.
_SQL_INSTITUTION_HEALTH = """
    SELECT
        dictGetOrDefault('trio_analytics.dict_institutions', 'name',
                         tuple(%(code)s), 'desconhecida')  AS institution_name,
        sum(total)                                          AS total,
        sum(settled)                                        AS settled,
        sum(failed)                                         AS failed,
        quantileMerge(0.95)(p95_state)                      AS p95_settlement_seconds,
        avgMerge(avg_state)                                 AS avg_settlement_seconds
      FROM (
        SELECT
            countMerge(cnt)                              AS total,
            if(status = 'settled', countMerge(cnt), 0)   AS settled,
            if(status = 'failed',  countMerge(cnt), 0)   AS failed,
            p95_seconds                                  AS p95_state,
            avg_seconds                                  AS avg_state
          FROM status_funnel
         WHERE source_institution = %(code)s
           AND hour >= %(since)s
         GROUP BY hour, type, status, p95_seconds, avg_seconds
      )
"""


@app.get("/institutions/{code}/health")
def institution_health(
    code: str = Path(..., min_length=1, max_length=16),
    hours: int = Query(1, ge=1, le=168),
):
    """Taxa de sucesso e P95 de liquidação da instituição na janela.

    É o endpoint de DECISÃO da API: um roteador de pagamentos consulta,
    encontra success_rate degradada ou P95 fora do acordado, e para de enviar
    Pix para essa instituição sem intervenção humana.
    """
    def build():
        rows, _ = db.query("SELECT max(created_at) FROM transactions_raw")
        anchor = rows[0][0] if rows and rows[0][0] else datetime.now(timezone.utc)
        since = anchor - _timedelta_hours(hours)

        rows, _ = db.query(_SQL_INSTITUTION_HEALTH, {"code": code, "since": since})
        if not rows:
            raise HTTPException(status_code=404, detail=f"instituição {code} sem dados")

        name, total, settled, failed, p95, avg = rows[0]
        total = int(total or 0)
        if total == 0:
            # 404 e não 200-com-zeros: para um roteador automatizado, "não sei"
            # e "está saudável com zero tráfego" levam a decisões opostas.
            raise HTTPException(
                status_code=404,
                detail=f"instituição {code} sem transações nas últimas {hours}h",
            )

        settled = int(settled or 0)
        failed = int(failed or 0)
        return {
            "institution": code,
            "institution_name": name,
            "window": f"{hours}h",
            "anchor": anchor.isoformat(),
            "total": total,
            "settled": settled,
            "failed": failed,
            "success_rate": round(settled / total, 4),
            "failure_rate": round(failed / total, 4),
            "p95_settlement_seconds": round(float(p95), 3) if p95 is not None else None,
            "avg_settlement_seconds": round(float(avg), 3) if avg is not None else None,
        }

    return _served("institution_health", ("institution_health", code, hours), build)


def _timedelta_hours(hours: int):
    from datetime import timedelta

    return timedelta(hours=hours)


# --- 3. Duplicatas suspeitas ---------------------------------------------
# Mesma lógica da Q4 do Desafio 1 exposta como serviço: mesmo valor, mesma
# origem e mesmo destino em janela curta. Como na Q4 otimizada, é uma window
# function com lag() — não o self-join da versão ingênua, que compararia cada
# linha com todas as outras.
_SQL_DUPLICATES = """
    SELECT external_id, tx_id, amount, created_at, status,
           source_account_id, destination_account_id,
           previous_at,
           dateDiff('second', previous_at, created_at) AS seconds_apart
      FROM (
        SELECT external_id, tx_id, amount, created_at, status,
               source_account_id, destination_account_id,
               lagInFrame(created_at) OVER (
                   PARTITION BY amount, source_account_id, destination_account_id
                   ORDER BY created_at
                   ROWS BETWEEN 1 PRECEDING AND CURRENT ROW
               ) AS previous_at
          FROM transactions_raw
         WHERE created_at >= %(since)s
           AND _is_deleted = 0
      )
     WHERE previous_at > 0
       AND dateDiff('second', previous_at, created_at) <= %(window_seconds)s
     ORDER BY created_at DESC
     LIMIT %(limit)s
"""


@app.get("/fraud/duplicates")
def fraud_duplicates(
    hours: int = Query(24, ge=1, le=168),
    window_seconds: int = Query(300, ge=1, le=3600),
    limit: int = Query(100, ge=1, le=1000),
):
    """Transações suspeitas de duplicidade — Q4 do Desafio 1 exposta como serviço."""
    def build():
        rows, _ = db.query("SELECT max(created_at) FROM transactions_raw")
        anchor = rows[0][0] if rows and rows[0][0] else datetime.now(timezone.utc)
        since = anchor - _timedelta_hours(hours)

        rows, _ = db.query(
            _SQL_DUPLICATES,
            {"since": since, "window_seconds": window_seconds, "limit": limit},
        )
        return {
            "window": f"{hours}h",
            "duplicate_window_seconds": window_seconds,
            "anchor": anchor.isoformat(),
            "count": len(rows),
            "data": [
                {
                    "external_id": str(r[0]),
                    "tx_id": int(r[1]),
                    "amount": float(r[2]),
                    "created_at": r[3].isoformat(),
                    "status": r[4],
                    "source_account_id": int(r[5]),
                    "destination_account_id": int(r[6]),
                    "previous_at": r[7].isoformat(),
                    "seconds_apart": int(r[8]),
                }
                for r in rows
            ],
        }

    return _served(
        "fraud_duplicates",
        ("fraud_duplicates", hours, window_seconds, limit),
        build,
    )


# --- Operacionais ---------------------------------------------------------
@app.get("/health")
def health():
    """Sonda para o orquestrador. Toca o ClickHouse de fato — um /health que só
    responde 200 porque o processo Python está vivo mentiria exatamente no
    cenário que interessa (banco fora, API de pé)."""
    try:
        db.query("SELECT 1")
        return {"status": "ok", "clickhouse": "ok"}
    except Exception as exc:  # noqa: BLE001
        return JSONResponse(
            status_code=503, content={"status": "degraded", "clickhouse": str(exc)}
        )


@app.get("/metrics")
def prometheus_metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)
