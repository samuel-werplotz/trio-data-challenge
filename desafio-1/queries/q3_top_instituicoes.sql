-- Q3 — Top 20 instituições por volume em 90 dias, com as 3 colunas exigidas
-- pelo PDF § 3.2 A.6.c: volume, tempo médio de liquidação e taxa de falha.
-- Versão ingênua: sem índice.
SELECT source_institution,
       count(*) AS transacoes,
       sum(amount) AS volume,
       avg(EXTRACT(EPOCH FROM (settled_at - created_at))) AS tempo_medio_seg,
       count(*) FILTER (WHERE status='failed')::numeric / count(*) AS taxa_falha
FROM transactions
WHERE created_at >= now() - INTERVAL '90 days'
GROUP BY source_institution
ORDER BY volume DESC LIMIT 20;
