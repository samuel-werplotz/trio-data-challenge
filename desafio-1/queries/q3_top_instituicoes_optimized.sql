-- Q3 otimizada — usa idx_tx_institution_created (covering: amount/status/
-- settled_at vêm do índice, sem heap fetch). Continua a query direta sobre
-- transactions (a versão que lê do CAgg de latência é a etapa 08).
SELECT source_institution,
       count(*) AS transacoes,
       sum(amount) AS volume,
       avg(EXTRACT(EPOCH FROM (settled_at - created_at))) AS tempo_medio_seg,
       count(*) FILTER (WHERE status='failed')::numeric / count(*) AS taxa_falha
FROM transactions
WHERE created_at >= now() - INTERVAL '90 days'
GROUP BY source_institution
ORDER BY volume DESC LIMIT 20;
