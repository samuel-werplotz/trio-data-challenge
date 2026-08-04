-- =============================================================================
--  PostgreSQL Legado — Scripts de inicialização
--  Simula o banco legado que pode migrar para Aurora/RDS.
--  
--  Sugestão:
--    01_schema.sql   — Tabelas de usuários, contas, configurações de parceiros
--    02_seed.sql     — Dados sintéticos
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
