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
