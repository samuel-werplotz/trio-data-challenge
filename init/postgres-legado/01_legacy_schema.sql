-- 01_legacy_schema.sql — schema do sistema legado (S07). Simula um banco de
-- 2015: SERIAL, TIMESTAMP sem timezone, VARCHAR com limite arbitrário, sem
-- FK entre camadas de negócio. O contraste com init/timescaledb/01_schema.sql
-- (IDENTITY, TIMESTAMPTZ, TEXT) é proposital — a análise de migração parte
-- justamente dessas dívidas técnicas.

-- partner_institutions e institution_configs alimentam o dict_institutions do
-- ClickHouse (etapa 11) e o ref-sync batch (etapa 14): sem esta origem real,
-- o Dictionary não teria de onde ler.
CREATE TABLE IF NOT EXISTS partner_institutions (
    id               SERIAL PRIMARY KEY,
    code             VARCHAR(10) NOT NULL UNIQUE,
    name             VARCHAR(200) NOT NULL,
    short_name       VARCHAR(50),
    inst_type        VARCHAR(30) NOT NULL,
    is_active        BOOLEAN NOT NULL DEFAULT true,
    -- TIMESTAMP sem fuso: armadilha real de sistema legado que opera em
    -- múltiplos fusos — deliberada, não descuido (S07 § Escolhas legadas).
    created_at       TIMESTAMP NOT NULL DEFAULT now(),
    updated_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS institution_configs (
    id                    SERIAL PRIMARY KEY,
    -- FK aqui é deliberado: legado prioriza integridade referencial sobre
    -- volume de escrita (baixo volume nesta tabela, ~450 linhas).
    institution_id        INT NOT NULL REFERENCES partner_institutions(id),
    config_key            VARCHAR(100) NOT NULL,
    config_value          TEXT NOT NULL,
    value_type            VARCHAR(20) NOT NULL DEFAULT 'string',
    effective_from        TIMESTAMP NOT NULL DEFAULT now(),
    effective_until       TIMESTAMP,
    updated_at            TIMESTAMP NOT NULL DEFAULT now(),
    UNIQUE (institution_id, config_key, effective_from)
);

CREATE TABLE IF NOT EXISTS legacy_users (
    id            SERIAL PRIMARY KEY,
    document      VARCHAR(14) NOT NULL UNIQUE,
    full_name     VARCHAR(200) NOT NULL,
    email         VARCHAR(200),
    status        VARCHAR(20) NOT NULL DEFAULT 'active',
    created_at    TIMESTAMP NOT NULL DEFAULT now(),
    last_login_at TIMESTAMP
);

CREATE TABLE IF NOT EXISTS legacy_accounts (
    id             SERIAL PRIMARY KEY,
    user_id        INT NOT NULL REFERENCES legacy_users(id),
    institution_id INT NOT NULL REFERENCES partner_institutions(id),
    account_number VARCHAR(20) NOT NULL,
    branch         VARCHAR(10),
    account_type   VARCHAR(20) NOT NULL DEFAULT 'checking',
    status         VARCHAR(20) NOT NULL DEFAULT 'active',
    balance        NUMERIC(18,2) NOT NULL DEFAULT 0,
    created_at     TIMESTAMP NOT NULL DEFAULT now(),
    updated_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- Índices das 2 queries complexas de S07 — criados aqui, não em arquivo
-- separado: ao contrário do TimescaleDB (etapa 06/07), esta etapa não separa
-- "antes sem índice" de "depois com índice" para o schema como um todo; o
-- antes/depois que importa aqui é do bloat (estatísticas desatualizadas),
-- não da ausência de índice.
CREATE INDEX IF NOT EXISTS idx_legacy_accounts_inst_status
    ON legacy_accounts (institution_id, status) INCLUDE (balance, user_id);

CREATE INDEX IF NOT EXISTS idx_institution_configs_lookup
    ON institution_configs (institution_id, config_key, effective_from DESC)
    WHERE effective_until IS NULL;
