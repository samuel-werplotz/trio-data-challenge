-- =============================================================================
--  TimescaleDB — schema transacional (S01). Roda na criação do container,
--  depois de 00_init.sql (extensões) e antes de 02_seed_marker.sql.
--  Sem índice além dos implícitos de PK/unique e sem política — de propósito:
--  a etapa 06 mede as queries "antes" de otimizar (03_indexes.sql é a etapa 07).
-- =============================================================================

-- ---------- Tipos customizados ----------
-- ENUM em vez de TEXT: 4 bytes fixos por valor, com validação pelo banco.
-- Trade-off aceito: adicionar valor novo exige ALTER TYPE fora de transação em
-- versões antigas. Aqui os valores são fixos por definição de negócio.
CREATE TYPE transaction_status AS ENUM ('pending','settled','failed','reversed');
CREATE TYPE transaction_type   AS ENUM ('pix','ted','boleto','card');
CREATE TYPE account_type       AS ENUM ('checking','payment','escrow');
CREATE TYPE account_status     AS ENUM ('active','blocked','closed');
CREATE TYPE holder_doc_type    AS ENUM ('cpf','cnpj');

-- ---------- accounts ----------
-- Criada antes de transactions por ser referenciada por ela (sem FK, ver abaixo).
-- Concentra toda a PII do sistema: tabela comum, NUNCA hypertable, NUNCA
-- comprimida — uma solicitação de exclusão LGPD precisa ser um UPDATE simples,
-- sem tocar em chunk comprimido (S05-LGPD-Sanitizacao).
CREATE TABLE accounts (
    id                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_number    TEXT           NOT NULL,
    institution_code  TEXT           NOT NULL,
    holder_document   TEXT           NOT NULL,  -- TEXT, não NUMERIC: CPF/CNPJ tem zero à esquerda
    holder_doc_type   holder_doc_type NOT NULL,
    holder_name       TEXT           NOT NULL,
    account_type      account_type   NOT NULL DEFAULT 'checking',
    status            account_status NOT NULL DEFAULT 'active',
    created_at        TIMESTAMPTZ    NOT NULL DEFAULT now(),

    -- número de conta só é único DENTRO de uma instituição, não globalmente
    CONSTRAINT uq_accounts_inst_number UNIQUE (institution_code, account_number)
);

-- ---------- transactions — a hypertable ----------
CREATE TABLE transactions (
    id                      BIGINT GENERATED ALWAYS AS IDENTITY,
    external_id             UUID           NOT NULL,
    amount                  NUMERIC(18,2)  NOT NULL CHECK (amount > 0),  -- NUMERIC, não FLOAT: centavos não podem desaparecer em agregação
    currency                CHAR(3)        NOT NULL DEFAULT 'BRL',
    status                  transaction_status NOT NULL DEFAULT 'pending',
    type                    transaction_type   NOT NULL,
    source_institution      TEXT           NOT NULL,
    destination_institution TEXT           NOT NULL,
    source_account_id       BIGINT,
    destination_account_id  BIGINT,
    created_at              TIMESTAMPTZ    NOT NULL DEFAULT now(),
    settled_at              TIMESTAMPTZ,
    updated_at              TIMESTAMPTZ    NOT NULL DEFAULT now(),  -- alimenta _version do ClickHouse e o watermark do plano B de CDC
    metadata                JSONB          NOT NULL DEFAULT '{}'::jsonb,

    -- hypertable exige que toda constraint única inclua a coluna de particionamento
    PRIMARY KEY (id, created_at),
    CONSTRAINT chk_settled_after_created
        CHECK (settled_at IS NULL OR settled_at >= created_at)

    -- Sem FK para accounts: deliberado. FK em hypertable verifica linha a linha
    -- e mataria a performance da carga de 10M. Integridade referencial fica a
    -- cargo da aplicação — prática real em alto volume.
    -- external_id sem UNIQUE: índice único global sobre 365 chunks é caro e
    -- forçaria incluir created_at, descaracterizando a unicidade. Índice
    -- não-único vem em 03_indexes.sql (etapa 07); unicidade real é do sistema
    -- de origem.
);

SELECT create_hypertable(
    'transactions',
    by_range('created_at', INTERVAL '1 day')
);

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Dispara só em UPDATE — não penaliza o COPY do seed (que são INSERTs).
CREATE TRIGGER trg_transactions_updated_at
    BEFORE UPDATE ON transactions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------- reconciliation_events ----------
CREATE TABLE reconciliation_events (
    id                 BIGINT GENERATED ALWAYS AS IDENTITY,
    transaction_id     BIGINT      NOT NULL,
    transaction_created_at TIMESTAMPTZ NOT NULL,  -- duplicado de transactions.created_at: permite exclusão de chunks dos dois lados no JOIN de Q2
    external_reference TEXT        NOT NULL,
    event_type         TEXT        NOT NULL,
    amount_expected    NUMERIC(18,2) NOT NULL,
    amount_received    NUMERIC(18,2) NOT NULL,
    difference         NUMERIC(18,2)
        GENERATED ALWAYS AS (amount_received - amount_expected) STORED,  -- STORED permite indexar; elimina inconsistência entre os 3 valores
    reconciled_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    notes              TEXT,

    PRIMARY KEY (id, reconciled_at)
);

-- chunk de 7 dias, não 1 dia: volume é ~10x menor que transactions (só eventos
-- de divergência/confirmação); chunk diário criaria 365 chunks minúsculos à toa.
SELECT create_hypertable(
    'reconciliation_events',
    by_range('reconciled_at', INTERVAL '7 days')
);
