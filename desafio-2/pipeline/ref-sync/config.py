"""config.py — configuração do ref-sync por variáveis de ambiente.
Mesmo padrão do sync-worker: nenhum segredo hardcoded, defaults válidos só
para o ambiente local do desafio.
"""
import os


class Config:
    # --- Origem: PostgreSQL legado ---
    # Porta 5432 é a interna da rede Docker; 5433 é a publicada no host.
    PG_HOST = os.environ.get("LEGACY_PGHOST", "postgres-legado")
    PG_PORT = int(os.environ.get("LEGACY_PGPORT", "5432"))
    PG_USER = os.environ.get("POSTGRES_USER", "trio")
    PG_PASSWORD = os.environ.get("POSTGRES_PASSWORD", "trio2024")
    PG_DATABASE = os.environ.get("LEGACY_POSTGRES_DB", "trio_legado")

    # --- Destino: ClickHouse ---
    CLICKHOUSE_HOST = os.environ.get("CLICKHOUSE_HOST", "clickhouse")
    CLICKHOUSE_PORT = int(os.environ.get("CLICKHOUSE_PORT", "8123"))
    CLICKHOUSE_USER = os.environ.get("CLICKHOUSE_USER", "trio")
    CLICKHOUSE_PASSWORD = os.environ.get("CLICKHOUSE_PASSWORD", "trio2024")
    CLICKHOUSE_DATABASE = os.environ.get("CLICKHOUSE_DATABASE", "trio_analytics")

    # Dicionário sincronizado. Só este existe no schema (S04); o
    # dict_institution_config citado em Container-Ref-Sync.md não foi declarado
    # e criá-lo aqui seria mudança de schema — fora do que esta etapa decide.
    DICTIONARY = os.environ.get("REF_DICTIONARY", "dict_institutions")

    # Tabela de origem do dicionário, usada para detectar mudança.
    SOURCE_TABLE = os.environ.get("REF_SOURCE_TABLE", "partner_institutions")

    # 5 minutos: o intervalo que a decisão de arquitetura fixa (D05). Dado de
    # referência muda em escala de semanas — ciclo mais curto só gastaria
    # conexão no legado sem entregar frescor que alguém consuma.
    POLL_INTERVAL_SECONDS = float(os.environ.get("REF_POLL_INTERVAL_SECONDS", "300"))

    # Mesma escada do sync-worker: 5 tentativas, ~31s no total. O legado é o
    # elo mais frágil do circuito (instância única, sem réplica), então falha
    # transitória de conexão não pode derrubar o laço.
    RETRY_DELAYS_SECONDS = [1, 2, 4, 8, 16]

    # Timeout da consulta de detecção. A query é trivial (max sobre ~200
    # linhas); se passar disso, o legado está degradado e é melhor falhar o
    # ciclo e alertar do que segurar a conexão.
    QUERY_TIMEOUT_SECONDS = int(os.environ.get("REF_QUERY_TIMEOUT_SECONDS", "10"))

    METRICS_PORT = int(os.environ.get("METRICS_PORT", "8002"))
