-- Q1 otimizada — lê de `cagg_volume_hourly` em vez dos 10M de `transactions`.
-- O ganho não vem de índice: vem de não tocar no dado bruto. O CAgg já reduziu
-- 10M de linhas a ~79k buckets horários; agrupar por mês daqui é rollup barato.
--
-- `sum(tx_count)` e `sum(total_amount)` são somáveis, então o rollup de hora
-- para mês é exato — nada de aproximação. (Média não seria: por isso ela sai de
-- sum/sum, e não de avg(avg_amount), que ponderaria errado buckets de tamanhos
-- diferentes.)
--
-- `date_trunc('hour', ...)` no corte não é cosmético: o bucket é a unidade
-- indivisível do CAgg. Um corte no meio da hora (o `now()` cru da versão
-- ingênua) incluiria o bucket inteiro de um lado e só parte das linhas do
-- outro, produzindo divergência no mês da borda. Alinhado à hora, o resultado
-- bate exatamente com a query sobre o raw — verificado linha a linha.
SELECT date_trunc('month', bucket) AS mes,
       type, status,
       sum(tx_count)    AS qtd,
       sum(total_amount) AS total
FROM cagg_volume_hourly
WHERE bucket >= date_trunc('hour', now() - INTERVAL '6 months')
GROUP BY 1,2,3
ORDER BY 1,2,3;
