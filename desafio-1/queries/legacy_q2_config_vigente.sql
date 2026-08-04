-- Legacy Q2 — configuração vigente com joins temporais (S07 § Query B).
-- O índice parcial (`WHERE effective_until IS NULL`) só ajuda depois de
-- ANALYZE atualizar a fração de linhas vigentes — antes disso o planner
-- subestima a seletividade e prefere Seq Scan mesmo com o índice disponível.
SELECT pi.code, pi.name, ic.config_key, ic.config_value, ic.value_type
FROM partner_institutions pi
JOIN institution_configs ic ON ic.institution_id = pi.id
WHERE pi.is_active
  AND ic.effective_from <= now()
  AND (ic.effective_until IS NULL OR ic.effective_until > now())
  AND ic.config_key IN ('daily_limit','pix_fee','settlement_window','max_tx_amount')
ORDER BY pi.code, ic.config_key;
