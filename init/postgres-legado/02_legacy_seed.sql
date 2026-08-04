-- 02_legacy_seed.sql — carga sintética do legado (S07 § Volume): 15
-- instituições, ~450 configs, 50.000 usuários, 80.000 contas. Idempotente via
-- guarda de contagem — reexecutar não duplica.

DO $$
BEGIN
    IF (SELECT count(*) FROM partner_institutions) > 0 THEN
        RAISE NOTICE 'seed já aplicado, pulando';
        RETURN;
    END IF;

    -- 15 instituições: mesma cardinalidade de source_institution em
    -- transactions (TimescaleDB), para o Dictionary da etapa 11 casar 1:1.
    INSERT INTO partner_institutions (code, name, short_name, inst_type, is_active)
    SELECT
        lpad(g::text, 3, '0'),
        'Instituição Parceira ' || g,
        'Parceira ' || g,
        (ARRAY['bank','fintech','broker'])[1 + (g % 3)],
        (g != 15)  -- 1 instituição inativa: exercita o WHERE is_active das 2 queries
    FROM generate_series(1, 15) g;

    -- 30 configs por instituição = ~450 linhas no total (S07 § Volume). As 4
    -- chaves que a Query B filtra ficam vigentes (`effective_until IS NULL`);
    -- as demais são histórico expirado da mesma chave — exercita o filtro
    -- temporal de verdade em vez de achar tudo vigente por acidente.
    INSERT INTO institution_configs (institution_id, config_key, config_value, value_type, effective_from, effective_until)
    SELECT
        pi.id,
        k.config_key,
        CASE WHEN v.rodada = 1 OR k.value_type != 'numeric' THEN k.config_value
             ELSE (k.config_value::numeric * (0.9 + v.rodada * 0.01))::text END,
        k.value_type,
        now() - ((v.rodada - 1) * 45 || ' days')::interval,
        CASE WHEN v.rodada = 1 THEN NULL  -- vigente: sem data de fim
             ELSE now() - ((v.rodada - 2) * 45 || ' days')::interval END
    FROM partner_institutions pi
    CROSS JOIN LATERAL (
        VALUES
            ('daily_limit',       (5000 + (pi.id * 137) % 45000)::text, 'numeric'),
            ('pix_fee',           round((0.10 + (pi.id % 5) * 0.05)::numeric, 2)::text, 'numeric'),
            ('settlement_window', (ARRAY['D+0','D+1','D+2'])[1 + pi.id % 3], 'string'),
            ('max_tx_amount',     (100000 + (pi.id * 977) % 900000)::text, 'numeric')
    ) AS k(config_key, config_value, value_type)
    -- rodada 1 = vigente; 2..8 = histórico (7 revisões por chave), fechando
    -- 15 inst × 4 chaves × 8 rodadas = 480 linhas, ~450 na ordem de grandeza de S07.
    CROSS JOIN generate_series(1, 8) v(rodada);

    -- 50.000 usuários. document sem validação de dígito verificador — legado
    -- não valida CPF na camada de banco (mais uma dívida deliberada).
    INSERT INTO legacy_users (document, full_name, email, status, created_at, last_login_at)
    SELECT
        lpad((g * 97 + 12345678900)::text, 11, '0'),
        'Usuário Legado ' || g,
        'usuario' || g || '@exemplo.com',
        CASE WHEN g % 50 = 0 THEN 'blocked' ELSE 'active' END,
        now() - (random() * 1800 || ' days')::interval,
        CASE WHEN g % 10 = 0 THEN NULL ELSE now() - (random() * 90 || ' days')::interval END
    FROM generate_series(1, 50000) g;

    -- 80.000 contas — 1.6 conta/usuário em média, distribuídas nas 15
    -- instituições. `id`s de users/institutions vêm de array ordenado, não
    -- assumidos sequenciais a partir de 1: SERIAL não é transacional, e uma
    -- reexecução após rollback (ex.: erro no meio do seed) deixa buracos.
    -- Arrays montados uma vez em CTE (não por linha) para não custar um
    -- scan+sort por conta gerada.
    WITH u AS (SELECT array_agg(id ORDER BY id) AS arr FROM legacy_users),
         i AS (SELECT array_agg(id ORDER BY id) AS arr FROM partner_institutions)
    INSERT INTO legacy_accounts (user_id, institution_id, account_number, branch, account_type, status, balance, created_at, updated_at)
    SELECT
        u.arr[1 + (g % 50000)],
        i.arr[1 + (g % 15)],
        lpad(g::text, 8, '0'),
        lpad((1 + g % 200)::text, 4, '0'),
        (ARRAY['checking','savings'])[1 + g % 2],
        CASE WHEN g % 40 = 0 THEN 'blocked' ELSE 'active' END,
        round((random() * 50000)::numeric, 2),
        now() - (random() * 1800 || ' days')::interval,
        now() - (random() * 30 || ' days')::interval
    FROM generate_series(1, 80000) g, u, i;
END $$;
