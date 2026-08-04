-- Q2 — Divergências de reconciliação > R$ 0,01, últimos 30 dias, com contas
-- de origem e destino (PDF § 3.2 A.6.b). Versão ingênua: sem índice.
-- t.created_at = r.transaction_created_at no ON não é redundante — permite
-- exclusão de chunks no lado de transactions (por isso a coluna é duplicada
-- em reconciliation_events, ver S01).
SELECT r.id, r.external_reference, r.amount_expected, r.amount_received,
       r.difference, t.external_id, t.type,
       sa.holder_name AS origem, da.holder_name AS destino
FROM reconciliation_events r
JOIN transactions t ON t.id = r.transaction_id
                   AND t.created_at = r.transaction_created_at
LEFT JOIN accounts sa ON sa.id = t.source_account_id
LEFT JOIN accounts da ON da.id = t.destination_account_id
WHERE r.reconciled_at >= now() - INTERVAL '30 days'
  AND abs(r.difference) > 0.01
ORDER BY abs(r.difference) DESC;
