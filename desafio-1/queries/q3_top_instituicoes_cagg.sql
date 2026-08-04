-- Q3 lendo de `cagg_settlement_latency_daily` — terceira versão da Q3.
-- A da etapa 07 (`q3_top_instituicoes_optimized.sql`) já era rápida via índice
-- covering; esta troca o índice pelo agregado e não toca no raw.
--
-- Todas as colunas usadas aqui são SOMÁVEIS, então o rollup de dia para o
-- período inteiro é exato:
--   tempo médio   = sum(latency)/sum(settled) — reconstruído da soma, nunca
--                   avg(avg), que ponderaria errado dias de tamanhos diferentes
-- A ordenação é por contagem, não por volume financeiro: `amount` não vive
-- neste CAgg (é o CAgg 1, por tipo/hora, que carrega valor). Para o ranking
-- por volume em R$, a versão de índice da etapa 07 continua sendo a certa.
--
-- TAXA DE FALHA NÃO SAI DESTE CAgg — e a armadilha vale ser explicada, porque
-- ela é silenciosa. O CAgg filtra `WHERE settled_at IS NOT NULL`, e nenhuma
-- transação `failed` tem `settled_at` (verificado: 0 de 35k na última semana).
-- Logo `failed_count` é sempre 0 aqui, e `sum(failed)/sum(total)` devolveria
-- 0.0000 para toda instituição — um número que parece um resultado e é só o
-- filtro se olhando no espelho. A taxa de falha correta vem do CAgg 1, que
-- agrega por `status` sem filtrar nada (ver `q1_..._optimized.sql`).
--
-- O P95/P99 NÃO sai daqui: percentil não é somável, e sem o toolkit
-- (`percentile_agg`) não há esboço a combinar. Ele vem de
-- `v_settlement_latency_percentiles`, que roda sobre o raw. Trade-off
-- documentado em 04_caggs_policies.sql.
SELECT source_institution,
       -- "liquidadas", não "transações": o CAgg só enxerga linhas com
       -- settled_at preenchido, então este total exclui failed/pending.
       sum(settled_count)                                    AS liquidadas,
       sum(latency_sum_seconds) / nullif(sum(settled_count), 0)
                                                             AS tempo_medio_seg,
       max(latency_max_seconds)                              AS pior_caso_seg
FROM cagg_settlement_latency_daily
-- alinhado ao bucket (1 dia) pelo mesmo motivo da Q1: cortar no meio do
-- bucket compararia laranja com maçã contra a versão sobre o raw.
WHERE bucket >= date_trunc('day', now() - INTERVAL '90 days')
GROUP BY source_institution
ORDER BY liquidadas DESC
LIMIT 20;
