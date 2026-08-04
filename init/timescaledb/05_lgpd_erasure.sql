-- 05_lgpd_erasure.sql — tabela de auditoria e procedimento de anonimização
-- LGPD (S09). Roda depois de 01_schema: referencia `accounts`.
-- Idempotente: pode reexecutar sobre um banco já inicializado.

-- `digest()`/sha256 do procedimento abaixo vêm do pgcrypto — não instalado
-- por padrão na imagem. Diferente do timescaledb_toolkit (etapa 08), isto
-- aqui é só uma extensão ausente sem binário faltando: `CREATE EXTENSION`
-- resolve, sem conflito com imagem fixada (Seção 2).
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ===========================================================================
-- Tabela de auditoria (S09 § Tabela de auditoria)
-- ===========================================================================
-- `document_hash`, nunca o documento em claro: uma tabela de auditoria de
-- exclusão que guardasse os CPFs excluídos seria autocontraditória. O hash
-- permite checar se um titular já solicitou exclusão sem armazenar o dado.
CREATE TABLE IF NOT EXISTS lgpd_erasure_log (
    id              BIGSERIAL PRIMARY KEY,
    document_hash   TEXT NOT NULL,
    requested_at    TIMESTAMPTZ NOT NULL,
    executed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    requester       TEXT NOT NULL,
    affected_rows   INT,
    -- true até o ciclo de expiração dos backups (365 dias) completar: marca
    -- que a exclusão está feita no ambiente ativo mas ainda pendente no
    -- backup mais antigo que ainda contém o dado. Vira relatório do DPO.
    backups_pending BOOLEAN DEFAULT true,
    notes           TEXT
);

-- ===========================================================================
-- Procedimento de anonimização — passo 1 do processo de 3 passos
-- ===========================================================================
-- Por que UPDATE e não DELETE: `transactions.source_account_id` referencia
-- `accounts.id`. Apagar a conta destruiria o histórico financeiro, que a
-- Trio é obrigada a manter por regulação do Banco Central (5 anos). A LGPD
-- reconhece esse conflito (Art. 16, I): descaracterizar o titular mantendo o
-- registro contábil é a solução, não a exceção.
--
-- Hash determinístico (não valor fixo tipo 'ANONIMIZADO' em holder_document)
-- porque `uq_accounts_inst_number` não cobre esse campo, mas duas
-- anonimizações concorrentes gravando o mesmo literal colidiriam em qualquer
-- índice futuro sobre holder_document — o hash amarra no id, que é único.
CREATE OR REPLACE PROCEDURE anonimizar_conta(p_account_id BIGINT, p_requester TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_document TEXT;
    v_affected INT;
BEGIN
    SELECT holder_document INTO v_document FROM accounts WHERE id = p_account_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'conta % não encontrada', p_account_id;
    END IF;

    -- registro de auditoria ANTES de apagar: se o UPDATE falhar, sabemos que
    -- a solicitação existiu mesmo sem execução — rastro nunca se perde.
    INSERT INTO lgpd_erasure_log (document_hash, requested_at, requester)
    VALUES (encode(digest(v_document, 'sha256'), 'hex'), now(), p_requester);

    UPDATE accounts
    SET holder_name     = 'ANONIMIZADO',
        holder_document = 'ANON-' || encode(digest(id::text || 'salt', 'sha256'), 'hex'),
        status          = 'closed'
    WHERE id = p_account_id;

    GET DIAGNOSTICS v_affected = ROW_COUNT;

    UPDATE lgpd_erasure_log
    SET affected_rows = v_affected
    WHERE id = (SELECT max(id) FROM lgpd_erasure_log WHERE requester = p_requester);
END;
$$;
