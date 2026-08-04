-- Legacy Q1 — contas ativas por instituição com agregações (S07 § Query A).
-- Gargalo típico: Nested Loop onde deveria haver Hash Join, causado por
-- estatísticas desatualizadas — o efeito direto do bloat de 5 rodadas sem
-- ANALYZE. "before" mede exatamente esse estado.
SELECT pi.code, pi.name,
       count(la.id) FILTER (WHERE la.status='active')  AS contas_ativas,
       count(la.id) FILTER (WHERE la.status='blocked') AS contas_bloqueadas,
       sum(la.balance) FILTER (WHERE la.status='active') AS saldo_total,
       avg(la.balance) FILTER (WHERE la.status='active') AS saldo_medio,
       count(DISTINCT lu.id) AS usuarios_distintos
FROM partner_institutions pi
LEFT JOIN legacy_accounts la ON la.institution_id = pi.id
LEFT JOIN legacy_users lu ON lu.id = la.user_id AND lu.status='active'
WHERE pi.is_active
GROUP BY pi.code, pi.name
ORDER BY saldo_total DESC NULLS LAST;
