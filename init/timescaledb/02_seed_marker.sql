-- =============================================================================
--  Tabela de controle do seed (S02 § Idempotência do seed). `make seed` verifica
--  finished_at: se não é nulo, avisa e sai sem recarregar — evita duplicar as
--  10M linhas e estragar as medições da etapa 06. `make seed-force` limpa antes.
-- =============================================================================

-- id fixo em 1 com CHECK: garante no máximo uma linha, funcionando como
-- singleton de estado.
CREATE TABLE seed_control (
    id          INT PRIMARY KEY DEFAULT 1,
    started_at  TIMESTAMPTZ,
    finished_at TIMESTAMPTZ,
    total_rows  BIGINT,

    CONSTRAINT single_row CHECK (id = 1)
);
