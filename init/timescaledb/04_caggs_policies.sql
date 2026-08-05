-- 04_caggs_policies.sql — continuous aggregates, compressão e retenção da
-- hypertable `transactions` (S03). Roda depois de 01_schema/03_indexes: os
-- CAggs leem de `transactions`, então a hypertable precisa já existir.
-- Idempotente: pode reexecutar sobre um banco já inicializado.

-- ===========================================================================
-- CAgg 1 — volume e valor por tipo, por hora
-- ===========================================================================
-- `status` entra no GROUP BY mesmo sem o requisito pedir: a Q1 do desafio
-- agrupa por tipo E status, e sem essa coluna aqui a Q1 continuaria varrendo
-- os 10M do raw. Agregar por status também dá taxa de falha de graça.
--
-- WITH NO DATA: materializar 12 meses de 10M linhas numa transação só é o
-- caminho curto para estourar memória. A carga vem depois, em lotes.
CREATE MATERIALIZED VIEW IF NOT EXISTS cagg_volume_hourly
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 hour', created_at) AS bucket,
    type,
    status,
    count(*)    AS tx_count,
    sum(amount) AS total_amount,
    avg(amount) AS avg_amount,
    min(amount) AS min_amount,
    max(amount) AS max_amount
FROM transactions
GROUP BY bucket, type, status
WITH NO DATA;

-- ===========================================================================
-- CAgg 2 — latência de liquidação por instituição, por dia
-- ===========================================================================
-- PERCENTIL NÃO É SOMÁVEL. Não se tira o P95 do dia a partir dos P95 de cada
-- hora: a função não é associativa e o erro é silencioso. A saída canônica do
-- TimescaleDB é `percentile_agg` (TDigest), que materializa um ESBOÇO da
-- distribuição — esboços combinam, percentis prontos não.
--
-- PLANO B EM USO: `percentile_agg` mora na extensão `timescaledb_toolkit`,
-- que NÃO existe na imagem fixada `timescale/timescaledb:latest-pg16`
-- (verificado: sem extensão e sem binários). Trocar a imagem violaria a
-- reprodutibilidade exigida, então adotamos o plano B previsto pelo próprio
-- S03: o CAgg materializa contagens e somas — que SÃO somáveis e rollupáveis —
-- e o P95/P99 sai de `percentile_cont` numa view comum sobre o raw filtrado
-- (ver `v_settlement_latency_percentiles` abaixo).
--
-- Custo assumido: os percentis não vêm pré-computados, então a query de
-- percentil ainda toca a hypertable. O que o CAgg resolve é todo o resto do
-- painel (contagem liquidada, taxa de falha, latência média/máxima por dia),
-- e essas colunas rollupam para mês/trimestre sem reprocessar o bruto.
CREATE MATERIALIZED VIEW IF NOT EXISTS cagg_settlement_latency_daily
WITH (timescaledb.continuous) AS
SELECT
    time_bucket('1 day', created_at) AS bucket,
    source_institution,
    type,
    count(*) FILTER (WHERE settled_at IS NOT NULL) AS settled_count,
    -- ATENÇÃO: com o `WHERE settled_at IS NOT NULL` do rodapé, esta coluna é
    -- sempre 0 — nenhuma transação `failed` chega a ter `settled_at`
    -- (verificado no dataset: 0 de 35k na última semana). Mantida porque o
    -- schema é contrato de S03, mas NÃO use este CAgg para taxa de falha: o
    -- resultado seria 0.0000 para toda instituição, um zero que parece
    -- métrica e é só o filtro se olhando no espelho. Taxa de falha vem do
    -- `cagg_volume_hourly`, que agrega por `status` sem filtrar.
    count(*) FILTER (WHERE status = 'failed')      AS failed_count,
    -- idem: `total_count` aqui é o total LIQUIDADO, não o total emitido.
    count(*)                                       AS total_count,
    -- somáveis: dão média e desvio corretos em qualquer rollup posterior.
    -- (sum/count reconstrói a média; sum_sq permite variância combinável.)
    sum(EXTRACT(EPOCH FROM (settled_at - created_at)))    AS latency_sum_seconds,
    sum(EXTRACT(EPOCH FROM (settled_at - created_at))
        * EXTRACT(EPOCH FROM (settled_at - created_at)))  AS latency_sum_sq_seconds,
    min(EXTRACT(EPOCH FROM (settled_at - created_at)))    AS latency_min_seconds,
    max(EXTRACT(EPOCH FROM (settled_at - created_at)))    AS latency_max_seconds
FROM transactions
WHERE settled_at IS NOT NULL
GROUP BY bucket, source_institution, type
WITH NO DATA;

-- Leitura dos percentis (plano B). `percentile_cont` é exata mas exige todas
-- as linhas ordenadas em memória — é justamente por isso que não pode ser
-- materializada num CAgg, e por isso ela vive aqui, numa view comum.
--
-- `type` NA CHAVE DE AGRUPAMENTO, e isso não é detalhe: os quatro instrumentos
-- têm SLA de liquidação separados por ordens de grandeza — Pix liquida em
-- ~1,2s (mediana), TED em ~45min, boleto em ~18h. Agrupar só por instituição
-- misturava as quatro distribuições numa só, e o P95 resultante era dominado
-- pela cauda do boleto: reportava ~15h de latência para instituições cujo Pix
-- liquida em segundos. O número não estava errado aritmeticamente — respondia
-- a pergunta errada. "P95 de liquidação" só tem sentido dentro de um mesmo
-- instrumento. O CAgg irmão (`cagg_settlement_latency_daily`) já agrupava por
-- `type`; era esta view que perdia a dimensão.
CREATE OR REPLACE VIEW v_settlement_latency_percentiles AS
SELECT
    time_bucket('1 day', created_at) AS bucket,
    source_institution,
    type,
    count(*) AS settled_count,
    percentile_cont(0.95) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (settled_at - created_at))) AS p95_seconds,
    percentile_cont(0.99) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (settled_at - created_at))) AS p99_seconds
FROM transactions
WHERE settled_at IS NOT NULL
GROUP BY bucket, source_institution, type;

-- Visão consolidada por instituição, para quando a pergunta é "qual o SLA
-- geral desta instituição". Mantida SEPARADA e com nome explícito: quem lê
-- `_all_types` sabe que está olhando distribuições misturadas, o que a view
-- anterior escondia.
CREATE OR REPLACE VIEW v_settlement_latency_percentiles_all_types AS
SELECT
    time_bucket('1 day', created_at) AS bucket,
    source_institution,
    count(*) AS settled_count,
    percentile_cont(0.95) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (settled_at - created_at))) AS p95_seconds,
    percentile_cont(0.99) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (settled_at - created_at))) AS p99_seconds
FROM transactions
WHERE settled_at IS NOT NULL
GROUP BY bucket, source_institution;

-- ===========================================================================
-- Materialização inicial — trimestre a trimestre
-- ===========================================================================
-- Uma chamada única sobre 12 meses seria uma transação gigante. Em lotes, cada
-- trimestre commita sozinho e a memória volta ao chão entre eles.
-- Os lotes cobrem 2025-07 a 2026-10 de propósito: o dataset vai de set/2025 a
-- ago/2026, e as bordas folgadas garantem que nenhum bucket fique de fora.
-- `refresh_continuous_aggregate` não roda dentro de bloco de transação — daí
-- os CALL soltos, e não um DO $$ ... $$.
CALL refresh_continuous_aggregate('cagg_volume_hourly', '2025-07-01'::timestamptz, '2025-10-01'::timestamptz);
CALL refresh_continuous_aggregate('cagg_volume_hourly', '2025-10-01'::timestamptz, '2026-01-01'::timestamptz);
CALL refresh_continuous_aggregate('cagg_volume_hourly', '2026-01-01'::timestamptz, '2026-04-01'::timestamptz);
CALL refresh_continuous_aggregate('cagg_volume_hourly', '2026-04-01'::timestamptz, '2026-07-01'::timestamptz);
CALL refresh_continuous_aggregate('cagg_volume_hourly', '2026-07-01'::timestamptz, '2026-10-01'::timestamptz);

CALL refresh_continuous_aggregate('cagg_settlement_latency_daily', '2025-07-01'::timestamptz, '2025-10-01'::timestamptz);
CALL refresh_continuous_aggregate('cagg_settlement_latency_daily', '2025-10-01'::timestamptz, '2026-01-01'::timestamptz);
CALL refresh_continuous_aggregate('cagg_settlement_latency_daily', '2026-01-01'::timestamptz, '2026-04-01'::timestamptz);
CALL refresh_continuous_aggregate('cagg_settlement_latency_daily', '2026-04-01'::timestamptz, '2026-07-01'::timestamptz);
CALL refresh_continuous_aggregate('cagg_settlement_latency_daily', '2026-07-01'::timestamptz, '2026-10-01'::timestamptz);

-- ===========================================================================
-- Políticas de refresh
-- ===========================================================================
-- `end_offset => 1 hour` é a linha que mais importa deste arquivo. Sem ele o
-- job materializaria o bucket da hora corrente, que AINDA está recebendo
-- escrita: grava-se um número pela metade e, como o job não revisita buckets
-- fora da janela de `start_offset`, aquele valor errado fica gravado para
-- sempre. O dashboard mostraria um número que muda sozinho.
-- `start_offset => 3 hours` rejanela as 3h anteriores, cobrindo evento que
-- chegou atrasado.
SELECT add_continuous_aggregate_policy('cagg_volume_hourly',
    start_offset      => INTERVAL '3 hours',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes',
    if_not_exists     => true);

-- Bucket diário, mas o mesmo `end_offset` de 1h: o dia corrente segue aberto,
-- e o start_offset de 3 dias rejanela o suficiente para liquidação atrasada.
SELECT add_continuous_aggregate_policy('cagg_settlement_latency_daily',
    start_offset      => INTERVAL '3 days',
    end_offset        => INTERVAL '1 hour',
    schedule_interval => INTERVAL '30 minutes',
    if_not_exists     => true);

-- ===========================================================================
-- Compressão
-- ===========================================================================
-- `segmentby = source_institution, type`: agrupa fisicamente as linhas
-- comprimidas por essas duas colunas, então um WHERE source_institution='001'
-- descomprime só os segmentos daquela instituição. São as colunas que
-- aparecem no filtro de quase toda query do desafio e têm cardinalidade baixa
-- (15 × 4 = 60 combinações) — cardinalidade alta criaria segmentos minúsculos
-- e destruiria a taxa.
-- `orderby = created_at DESC, status`: o dado já chega nessa ordem, então
-- valores próximos ficam vizinhos e o delta-encoding rende; `status` desempata
-- agrupando valores iguais.
ALTER TABLE transactions SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'source_institution, type',
    timescaledb.compress_orderby   = 'created_at DESC, status'
);

SELECT add_compression_policy('transactions', INTERVAL '7 days', if_not_exists => true);

-- ===========================================================================
-- Retenção
-- ===========================================================================
-- A ordem entre retenção e refresh não pode ser invertida: a retenção apaga
-- chunk bruto, e se o CAgg ainda não materializou aquele período o agregado
-- fica com buraco PERMANENTE — a origem já não existe para reprocessar. Aqui
-- o refresh cobre 3h/3d atrás e a retenção só age aos 90 dias: margem de sobra.

-- Raw: 90 dias, conforme o enunciado. CRIADA E DESLIGADA logo abaixo.
SELECT add_retention_policy('transactions', INTERVAL '90 days', if_not_exists => true);

-- O conflito, dito na cara: o desafio pede 12 meses de dado E retenção de 90
-- dias. Aplicar a política literalmente apagaria 9 dos 12 meses do dataset de
-- demonstração. A política existe (é a política correta para produção) mas
-- fica `scheduled => false`; `scripts/retention-demo.sh` liga, demonstra e
-- desliga. Fingir que não há conflito seria menos honesto que documentá-lo.
SELECT alter_job(job_id, scheduled => false)
FROM timescaledb_information.jobs
WHERE proc_name = 'policy_retention'
  AND hypertable_name = 'transactions';

-- Assimetria deliberada: a retenção dos CAggs fica HABILITADA. O dataset tem
-- 12 meses e a janela é de 2 anos, então ela não apaga nada hoje — é a
-- política correta e inofensiva, ao contrário da do raw.
SELECT add_retention_policy('cagg_volume_hourly', INTERVAL '2 years', if_not_exists => true);
SELECT add_retention_policy('cagg_settlement_latency_daily', INTERVAL '2 years', if_not_exists => true);
