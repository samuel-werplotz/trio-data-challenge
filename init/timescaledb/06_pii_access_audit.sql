-- 06_pii_access_audit.sql — trilha de auditoria de LEITURA de PII.
--
-- Encaixe no fluxo: `accounts` é a única tabela com dado pessoal (S01). O
-- projeto já registrava o APAGAMENTO (lgpd_erasure_log, 05_lgpd_erasure.sql),
-- mas não a LEITURA — e numa fiscalização de Instituição de Pagamento a
-- primeira pergunta é "quem consultou dados de titular, quando, e quantos".
--
-- Por que não `pgaudit`: a extensão não existe na imagem fixada
-- (`pg_available_extensions` não a lista) e trocar a imagem violaria a
-- reprodutibilidade que é requisito do desafio. Mesma classe de decisão do
-- `percentile_agg` na etapa 08: usar o caminho nativo e declarar o trade-off.
--
-- O que este arquivo entrega e o que não entrega está em
-- docs/SEGURANCA-E-GOVERNANCA.md § 4.

-- ---------------------------------------------------------------------------
-- A trilha
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pii_access_log (
    id            BIGSERIAL PRIMARY KEY,
    accessed_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    db_user       TEXT         NOT NULL DEFAULT current_user,
    -- session_user difere de current_user quando há SET ROLE: guardar os dois
    -- é o que impede "assumi outro papel" de apagar o rastro de quem entrou.
    session_user_name TEXT     NOT NULL DEFAULT session_user,
    client_addr   INET,
    application   TEXT,
    purpose       TEXT,
    rows_returned INTEGER,
    query_text    TEXT
);

COMMENT ON TABLE pii_access_log IS
    'Trilha de leitura de accounts (PII). Contrapartida de lgpd_erasure_log, que registra apagamento.';

CREATE INDEX IF NOT EXISTS idx_pii_access_log_at   ON pii_access_log (accessed_at DESC);
CREATE INDEX IF NOT EXISTS idx_pii_access_log_user ON pii_access_log (db_user, accessed_at DESC);

-- ---------------------------------------------------------------------------
-- O caminho auditado de leitura
-- ---------------------------------------------------------------------------
-- Função em vez de view: uma view não consegue registrar quantas linhas
-- devolveu nem exigir a justificativa de acesso. Aqui o `p_purpose` é
-- obrigatório — acesso a dado de titular sem finalidade declarada é
-- exatamente o que a LGPD (art. 37) manda não existir.
CREATE OR REPLACE FUNCTION read_accounts_audited(
    p_purpose        TEXT,
    p_institution    TEXT DEFAULT NULL,
    p_limit          INTEGER DEFAULT 100
)
RETURNS TABLE (
    id               BIGINT,
    account_number   TEXT,
    institution_code TEXT,
    holder_document  TEXT,
    holder_name      TEXT,
    account_type     TEXT,
    status           TEXT
)
LANGUAGE plpgsql
-- SECURITY DEFINER: o chamador não precisa (e não deve) ter SELECT direto em
-- `accounts`. O acesso passa a existir só por esta porta, que registra.
SECURITY DEFINER
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF p_purpose IS NULL OR btrim(p_purpose) = '' THEN
        RAISE EXCEPTION 'finalidade do acesso é obrigatória (LGPD art. 37)';
    END IF;

    RETURN QUERY
        SELECT a.id, a.account_number, a.institution_code,
               a.holder_document, a.holder_name,
               a.account_type::TEXT, a.status::TEXT
          FROM accounts a
         WHERE (p_institution IS NULL OR a.institution_code = p_institution)
         LIMIT p_limit;

    GET DIAGNOSTICS v_count = ROW_COUNT;

    -- O registro é gravado DEPOIS de saber quantas linhas saíram: auditoria
    -- que só diz "alguém consultou" não distingue 1 titular de 80.000.
    INSERT INTO pii_access_log (
        client_addr, application, purpose, rows_returned, query_text
    ) VALUES (
        inet_client_addr(),
        current_setting('application_name', true),
        p_purpose,
        v_count,
        format('read_accounts_audited(institution=%s, limit=%s)',
               coalesce(p_institution, 'TODAS'), p_limit)
    );
END;
$$;

COMMENT ON FUNCTION read_accounts_audited IS
    'Única porta auditada para ler PII de accounts. Exige finalidade declarada e registra a contagem de linhas.';

-- ---------------------------------------------------------------------------
-- Integridade da trilha
-- ---------------------------------------------------------------------------
-- Auditoria que o próprio auditado pode reescrever não é auditoria. Sem
-- pgaudit não há append-only garantido pelo servidor, então o mais próximo
-- disso aqui é impedir UPDATE/DELETE por gatilho e mandar a trilha para
-- destino separado no backup (docs/SEGURANCA-E-GOVERNANCA.md § 7).
CREATE OR REPLACE FUNCTION pii_access_log_is_append_only()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'pii_access_log é append-only: % não é permitido', TG_OP;
END;
$$;

DROP TRIGGER IF EXISTS trg_pii_access_log_append_only ON pii_access_log;
CREATE TRIGGER trg_pii_access_log_append_only
    BEFORE UPDATE OR DELETE ON pii_access_log
    FOR EACH ROW EXECUTE FUNCTION pii_access_log_is_append_only();
