-- =============================================================================
--  Índices de otimização (S06). Aplicados via `make indexes`, DEPOIS da carga
--  de 10M — criar índice durante COPY é ordens de magnitude mais lento, e o
--  desafio pede EXPLAIN antes/depois: se o índice já existisse no init, não
--  haveria "antes" honesto para medir (etapa 06).
-- =============================================================================

-- ---------- Q2: divergências de reconciliação ----------

-- Índice PARCIAL: cobre só as linhas divergentes (~8% do total, medido no
-- REPORT.md), não a tabela inteira. Fica ~12x menor, cabe em memória e
-- atualiza mais rápido. O WHERE aqui precisa casar com o WHERE de Q2 para o
-- planejador poder usar o índice — é o detalhe que faz índice parcial ser
-- ignorado quando mal construído.
CREATE INDEX IF NOT EXISTS idx_recon_divergent
    ON reconciliation_events (reconciled_at DESC, transaction_id)
    WHERE abs(difference) > 0.01;

-- INCLUDE transforma em Index Only Scan: holder_name/institution_code vêm do
-- próprio índice, sem visitar a tabela accounts (elimina o heap fetch).
CREATE INDEX IF NOT EXISTS idx_accounts_id_covering
    ON accounts (id) INCLUDE (holder_name, institution_code);

-- ---------- Q3: top instituições por volume ----------

CREATE INDEX IF NOT EXISTS idx_tx_institution_created
    ON transactions (source_institution, created_at DESC)
    INCLUDE (amount, status, settled_at);

-- ---------- Q4: detecção de duplicatas ----------

-- Alinha a ordem física com o PARTITION BY ... ORDER BY da window function
-- (versão otimizada de Q4), permitindo que o Postgres pule o passo de
-- ordenação. O WHERE parcial exclui failed/reversed: transação que falhou e
-- foi reenviada não é duplicata suspeita, é comportamento correto — reduz o
-- índice e melhora a precisão do resultado.
CREATE INDEX IF NOT EXISTS idx_tx_dup_detection
    ON transactions (source_account_id, destination_account_id, amount, created_at)
    WHERE status IN ('settled','pending');

-- ---------------------------------------------------------------------------
-- idx_tx_updated_at — pré-requisito do sync-worker (micro-batch por watermark).
-- A janela incremental é `WHERE updated_at >= marca`, e sem este índice ela vira
-- Seq Scan de 10M + Sort a cada ciclo (medido: 85.587 buffers para 1 linha).
--
-- ATENÇÃO ao usar: o índice sozinho não basta. A hypertable é particionada por
-- created_at, então filtrar só por updated_at não exclui chunk nenhum (o plano
-- mostra "Chunks excluded during startup: 0") e o planner varre os 338. A query
-- do worker precisa carregar TAMBÉM um predicado em created_at:
--
--   WHERE updated_at >= :marca - interval '30 seconds'
--     AND created_at >= :marca - interval '7 days'
--
-- Com os dois predicados: 85.587 -> 17 buffers, e o Merge Append sobre índices
-- já ordenados dispensa o Sort do ORDER BY. Medição em PREMISSAS-VERIFICADAS.md.
--
-- CONCURRENTLY não é aceito aqui: "hypertables do not support concurrent index
-- creation". A criação normal propaga para os 338 chunks em ~1,4s.
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_tx_updated_at ON transactions (updated_at, id);
