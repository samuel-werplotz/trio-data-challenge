-- Query do Grafana em sub-segundo (S04 § A query do Grafana em sub-segundo).
-- Requisito: taxa de sucesso de transações Pix por instituição por hora nas
-- últimas 24h, comparada ao mesmo horário do dia anterior (delta %).
--
-- Os 4 fatores que entregam o sub-segundo:
-- 1. Lê de status_funnel (MV agregada) — dezenas de milhares de linhas, não
--    os 10M de transactions_raw.
-- 2. Uma passada para os dois períodos — 48h de uma vez com classificação
--    por if(), em vez de dois SELECTs separados.
-- 3. type='pix' é a primeira coluna do ORDER BY de status_funnel — o índice
--    esparso corta a maior parte dos dados logo no começo.
-- 4. Filtro de partição — 48h tocam no máximo 2 partições mensais.
--
-- Nota sobre `status`: nesta MV `status` é coluna do GROUP BY (uma linha por
-- hora/instituição/status), não um filtro pré-agregado dentro de `cnt` como
-- a query ilustrativa de S04 assumia (`countIfMerge` exige um estado gerado
-- por `countIfState`, e `cnt` foi gravado com `countState()` puro). "Sucesso"
-- é derivado aqui filtrando `status='settled'` na leitura, via `sumIf` sobre
-- o valor já desagregado por `countMerge`.
WITH janelas AS (
    SELECT
        hour,
        source_institution,
        status,
        if(hour >= now() - INTERVAL 24 HOUR, 'hoje', 'ontem') AS periodo,
        countMerge(cnt) AS qtd
    FROM trio_analytics.status_funnel
    WHERE type = 'pix'
      AND hour >= now() - INTERVAL 48 HOUR
    GROUP BY hour, source_institution, status, periodo
),
somado AS (
    SELECT hour, source_institution, periodo,
           sumIf(qtd, status = 'settled') AS total,
           sum(qtd)                       AS todos
    FROM janelas
    GROUP BY hour, source_institution, periodo
),
taxas AS (
    SELECT
        toHour(hour) AS h,
        source_institution,
        periodo,
        sum(total) / nullIf(sum(todos), 0) AS taxa_sucesso
    FROM somado GROUP BY h, source_institution, periodo
)
SELECT
    h AS hora,
    dictGetOrDefault('trio_analytics.dict_institutions','name',
                     tuple(source_institution), source_institution) AS instituicao,
    round(100 * anyIf(taxa_sucesso, periodo='hoje'), 2)  AS taxa_hoje,
    round(100 * anyIf(taxa_sucesso, periodo='ontem'), 2) AS taxa_ontem,
    round(100 * (anyIf(taxa_sucesso, periodo='hoje') -
                 anyIf(taxa_sucesso, periodo='ontem')), 2) AS delta_pp
FROM taxas
GROUP BY hora, instituicao
ORDER BY hora, instituicao;
