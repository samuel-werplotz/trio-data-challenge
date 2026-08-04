-- Q2 otimizada — usa idx_recon_divergent (parcial) + idx_accounts_id_covering
-- (Index Only Scan via INCLUDE). t.created_at = r.transaction_created_at no ON
-- permite exclusão de chunks no lado de transactions — sem essa condição o
-- join varreria os 338 chunks.
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
