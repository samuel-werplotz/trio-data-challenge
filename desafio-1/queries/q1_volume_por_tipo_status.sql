-- Q1 — Volume e valor por tipo e status, por mês, últimos 6 meses (S06).
-- Versão ingênua: nenhum índice, nenhum CAgg — baseline para a etapa 07/08
-- medirem o ganho real da otimização contra este "antes".
SELECT date_trunc('month', created_at) AS mes,
       type, status,
       count(*) AS qtd, sum(amount) AS total
FROM transactions
WHERE created_at >= now() - INTERVAL '6 months'
GROUP BY 1,2,3
ORDER BY 1,2,3;
