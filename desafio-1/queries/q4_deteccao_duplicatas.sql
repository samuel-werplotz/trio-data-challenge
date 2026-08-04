-- Q4 — Detecção de duplicatas em janela de 5 minutos (S06).
-- ANTI-PADRÃO DELIBERADO: self-join. O planejador tende a Nested Loop ou hash
-- join com explosão de combinações — lento em 7 dias, inviável em 90. Medido
-- de propósito para comparar contra a versão com window function (etapa 07).
SELECT a.id, b.id, a.amount, a.created_at, b.created_at
FROM transactions a
JOIN transactions b
  ON a.amount = b.amount
 AND a.source_account_id = b.source_account_id
 AND a.destination_account_id = b.destination_account_id
 AND b.created_at BETWEEN a.created_at AND a.created_at + INTERVAL '5 minutes'
 AND a.id < b.id
WHERE a.created_at >= now() - INTERVAL '7 days';
