"""config.py — configuração do sync-worker por variáveis de ambiente.
Nenhum segredo hardcoded; os defaults valem só para o ambiente local do desafio.
"""
import os


class Config:
    # --- Origem: TimescaleDB ---
    PG_HOST = os.environ.get("PGHOST", "timescaledb")
    PG_PORT = int(os.environ.get("PGPORT", "5432"))
    PG_USER = os.environ.get("POSTGRES_USER", "trio")
    PG_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "trio2024")
    PG_DATABASE = os.environ.get("POSTGRES_DB", "trio_transactions")

    # --- Destino: ClickHouse ---
    CLICKHOUSE_HOST = os.environ.get("CLICKHOUSE_HOST", "clickhouse")
    CLICKHOUSE_PORT = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
    CLICKHOUSE_USER = os.environ.get("CLICKHOUSE_USER", "trio")
    CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "trio2024")
    CLICKHOUSE_DATABASE = os.environ.get("CLICKHOUSE_DATABASE", "trio_analytics")
    CLICKHOUSE_TABLE = os.environ.get("CLICKHOUSE_TABLE", "transactions_raw")

    SYNC_SOURCE = "transactions"

    # Intervalo entre ciclos. Freshness alvo < 30s: 10s de ciclo deixa margem
    # para o próprio tempo de leitura e escrita.
    POLL_INTERVAL_SECONDS = float(os.environ.get("POLL_INTERVAL_SECONDS", "10"))

    # Relê OVERLAP segundos antes do watermark. Cobre commit que só ficou visível
    # depois de a janela anterior ter sido lida: uma transação longa recebe
    # updated_at no momento do UPDATE, mas só se torna visível no COMMIT — sem a
    # sobreposição, a linha cairia no vão entre duas janelas. A releitura é
    # inofensiva porque o ReplacingMergeTree deduplica por (ORDER BY, _version).
    OVERLAP_SECONDS = int(os.environ.get("OVERLAP_SECONDS", "30"))

    # Teto de linhas por ciclo: mantém memória e duração previsíveis. Se a janela
    # tiver mais que isso, o ciclo seguinte continua de onde parou.
    BATCH_MAX_ROWS = int(os.environ.get("BATCH_MAX_ROWS", "50000"))

    # Janela de created_at do ciclo normal. NÃO é cosmético: a hypertable é
    # particionada por created_at, então sem este predicado o planner não exclui
    # nenhum chunk e varre os 338 (medido: 85.587 buffers vs 17 com o filtro).
    # Ver PREMISSAS-VERIFICADAS.md § P2b.
    CREATED_AT_WINDOW_DAYS = int(os.environ.get("CREATED_AT_WINDOW_DAYS", "7"))

    # A janela acima é o que torna o ciclo barato, mas ela cega o worker para
    # UPDATE em transação mais antiga que 7 dias (estorno tardio, reconciliação).
    # A varredura completa periódica é a rede que cobre esse caso.
    FULL_SCAN_INTERVAL_HOURS = int(os.environ.get("FULL_SCAN_INTERVAL_HOURS", "24"))

    RETRY_DELAYS_SECONDS = [1, 2, 4, 8, 16]

    METRICS_PORT = int(os.environ.get("METRICS_PORT", "8001"))
