-- 06_sync_state.sql — estado do sync-worker (pipeline TimescaleDB -> ClickHouse).
-- Guarda o watermark de cada origem sincronizada. É a única coisa que o worker
-- persiste: matar e religar o processo não perde nem duplica trabalho.
--
-- Por que watermark e não CDC: publish_via_partition_root não funciona sobre
-- hypertable (não é tabela particionada nativa — relkind='r'), então Debezium
-- nunca recebe as escritas dos chunks. Ver AUDITORIA-E-REPLANEJAMENTO.md § 4.1.

CREATE TABLE IF NOT EXISTS sync_state (
    source            TEXT PRIMARY KEY,
    -- Fronteira do que já foi sincronizado. O worker relê a partir daqui menos
    -- o overlap; só avança DEPOIS que o ClickHouse confirma a escrita. É essa
    -- ordem que garante que uma falha no meio do ciclo não perca linha nenhuma
    -- (a releitura é absorvida pelo ReplacingMergeTree via _version).
    last_updated_at   TIMESTAMPTZ NOT NULL,
    last_run_at       TIMESTAMPTZ,
    rows_synced       BIGINT      NOT NULL DEFAULT 0,
    -- Marca a varredura diária ampla, que existe para pegar UPDATE em transação
    -- antiga: o ciclo normal filtra created_at dos últimos 7 dias para ativar a
    -- exclusão de chunks, e por isso não enxerga linha mais velha que isso.
    last_full_scan_at TIMESTAMPTZ
);

COMMENT ON TABLE sync_state IS
  'Watermark do sync-worker. Uma linha por origem sincronizada.';
COMMENT ON COLUMN sync_state.last_updated_at IS
  'Maior updated_at já confirmado no destino. Avança só após a escrita.';

-- Semente: início do dataset, para o primeiro ciclo não varrer o histórico
-- inteiro (os 10M já foram para o ClickHouse pelo backfill da etapa 12).
INSERT INTO sync_state (source, last_updated_at)
VALUES ('transactions', now())
ON CONFLICT (source) DO NOTHING;
