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
    -- Desempate do watermark. NÃO é redundante com last_updated_at.
    --
    -- `now()` no PostgreSQL é fixo por statement: um INSERT de N linhas grava o
    -- MESMO updated_at em todas. Quando N > BATCH_MAX_ROWS, o LIMIT corta no
    -- meio de um timestamp e o watermark passa a apontar para um instante que
    -- ainda tem linhas não lidas. Com o filtro sendo `updated_at > watermark`,
    -- essas linhas eram descartadas a cada ciclo — para sempre, em silêncio.
    --
    -- Medido na etapa 20: 60.000 linhas num statement, 50.000 sincronizadas,
    -- 10.000 perdidas e o worker parado sem erro no log.
    --
    -- Com (updated_at, id) o corte fica exato: o ORDER BY já era
    -- (updated_at, id), então a retomada continua de onde parou dentro do
    -- mesmo timestamp.
    last_id           BIGINT      NOT NULL DEFAULT 0,
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
COMMENT ON COLUMN sync_state.last_id IS
  'Desempate: maior id dentro de last_updated_at. Sem ele, lote maior que BATCH_MAX_ROWS com updated_at idêntico perde as linhas excedentes (etapa 20).';

-- Migração para base existente: a coluna nasceu na etapa 20.5, depois de o
-- ambiente já estar carregado. ADD COLUMN IF NOT EXISTS mantém a subida limpa
-- tanto em volume novo quanto em volume que já tinha a tabela antiga.
ALTER TABLE sync_state ADD COLUMN IF NOT EXISTS last_id BIGINT NOT NULL DEFAULT 0;

-- Semente: início do dataset, para o primeiro ciclo não varrer o histórico
-- inteiro (os 10M já foram para o ClickHouse pelo backfill da etapa 12).
INSERT INTO sync_state (source, last_updated_at)
VALUES ('transactions', now())
ON CONFLICT (source) DO NOTHING;
