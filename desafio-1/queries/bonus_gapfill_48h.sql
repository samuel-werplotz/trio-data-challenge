-- Query bônus — gapfill de 48h (S06). Três limites obrigatórios do
-- time_bucket_gapfill: início e fim explícitos, mais o WHERE correspondente
-- (sem eles o Postgres não sabe qual intervalo preencher e retorna erro).
-- coalesce(count(*), 0) em vez de locf: hora sem transação é ZERO, não
-- "repita o último". Já para valor médio, locf faz sentido — o ticket médio
-- não vira zero só porque ninguém transacionou naquela hora.
SELECT time_bucket_gapfill('1 hour', created_at,
                           now() - INTERVAL '48 hours', now()) AS hora,
       type,
       coalesce(count(*), 0)              AS transacoes,
       locf(avg(amount))                  AS valor_medio_locf,
       interpolate(avg(amount))           AS valor_medio_interp
FROM transactions
WHERE created_at >= now() - INTERVAL '48 hours'
  AND created_at <  now()
GROUP BY hora, type
ORDER BY hora, type;
