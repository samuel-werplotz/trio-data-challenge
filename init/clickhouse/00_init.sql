-- =============================================================================
--  ClickHouse — Scripts de inicialização
--  
--  Sugestão:
--    01_schema.sql           — Tabelas principais, engines, particionamento
--    02_materialized_views.sql — Materialized Views para pré-agregação
--    03_dictionaries.sql     — Dictionaries para dados de referência
-- =============================================================================

CREATE DATABASE IF NOT EXISTS trio_analytics;
