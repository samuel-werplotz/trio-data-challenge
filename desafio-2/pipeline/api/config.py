"""config.py — configuração da API por variáveis de ambiente.
Mesmo padrão do sync-worker e do ref-sync: nenhum segredo hardcoded.
"""
import os


class Config:
    CLICKHOUSE_HOST = os.environ.get("CLICKHOUSE_HOST", "clickhouse")
    CLICKHOUSE_PORT = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
    CLICKHOUSE_USER = os.environ.get("CLICKHOUSE_USER", "trio")
    CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "trio2024")
    CLICKHOUSE_DATABASE = os.environ.get("CLICKHOUSE_DATABASE", "trio_analytics")

    # Pool de conexão: reconectar a cada requisição derruba o banco sob carga
    # (Container-API.md). 8 é folgado para o perfil desta API — as queries são
    # curtas e o ClickHouse prefere poucas conexões com trabalho grande a muitas
    # conexões ociosas.
    POOL_SIZE = int(os.environ.get("API_POOL_SIZE", "8"))

    # Cache de 10s: cem usuários no mesmo minuto = uma query, não cem. 10s é
    # curto o bastante para um painel de operações não parecer congelado e
    # longo o bastante para absorver o refresh automático de um dashboard.
    CACHE_TTL_SECONDS = float(os.environ.get("API_CACHE_TTL_SECONDS", "10"))

    # Timeout da query: query travada não pode segurar a conexão para sempre.
    # Aplicado no servidor (max_execution_time), não só no cliente — cancelar
    # do lado do cliente deixaria o ClickHouse trabalhando de graça.
    QUERY_TIMEOUT_SECONDS = int(os.environ.get("API_QUERY_TIMEOUT_SECONDS", "5"))

    API_PORT = int(os.environ.get("API_PORT", "8000"))
