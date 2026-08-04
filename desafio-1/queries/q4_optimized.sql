-- Q4 otimizada — window function em vez do self-join (anti-padrão da versão
-- ingênua). Uma passada com ordenação, em vez de comparar cada linha com
-- todas as outras. idx_tx_dup_detection alinha a ordem física com o
-- PARTITION BY ... ORDER BY, deixando o Postgres pular o passo de ordenação.
WITH ordenadas AS (
    SELECT id, external_id, amount, created_at, status,
           source_account_id, destination_account_id,
           LAG(created_at) OVER w AS anterior_em,
           LAG(id)         OVER w AS anterior_id
    FROM transactions
    WHERE created_at >= now() - INTERVAL '7 days'
    WINDOW w AS (
        PARTITION BY amount, source_account_id, destination_account_id
        ORDER BY created_at
    )
)
SELECT id, anterior_id, external_id, amount, created_at, anterior_em,
       EXTRACT(EPOCH FROM (created_at - anterior_em)) AS segundos_entre
FROM ordenadas
WHERE anterior_em IS NOT NULL
  AND created_at - anterior_em <= INTERVAL '5 minutes'
ORDER BY created_at DESC;
