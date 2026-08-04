-- =============================================================================
--  TimescaleDB — Scripts de inicialização
--  Coloque aqui seus scripts .sql que serão executados na criação do container.
--  Eles rodam em ordem alfabética.
--  
--  Sugestão:
--    01_extensions.sql   — CREATE EXTENSION IF NOT EXISTS timescaledb, pg_stat_statements, etc.
--    02_schema.sql       — Tabelas, hypertables, índices
--    03_policies.sql     — Continuous aggregates, compressão, retenção
-- =============================================================================

-- Habilita extensões necessárias
CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
