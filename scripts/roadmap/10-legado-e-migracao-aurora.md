# 10 — LEGADO E MIGRAÇÃO AURORA  [compose]

## ORIGEM
`../vault-estudo/06-Especificacao/S07-Legado-e-Backup.md` § Parte 1 — Schema do legado · § Escolhas deliberadamente "legadas" · § Volume e Bloat proposital · § As duas queries complexas · § Parte 4 — Documentação AWS (escrita, não executada); PDF § 3.2 Parte B

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
<preenchido pela etapa 09 ao fechar>

## ESCOPO
Faz: `desafio-1/schemas/02_legacy.sql` com o schema legado (`SERIAL`, `TIMESTAMP` sem timezone, `VARCHAR` — escolhas legadas deliberadas), seed de 50k usuários + 80k contas + a tabela de **parâmetros de configuração de instituições parceiras**, bloat induzido em 5 rodadas, 2 queries complexas com `EXPLAIN` antes/depois, e `desafio-1/migration-analysis.md` de 1 página.
Não faz: **não provisiona nada na AWS** — a análise de migração é documento escrito, nunca executado. Não usa CDC no legado: a decisão é batch de 5 min (etapa 14).

## PASSOS
1. Escrever `02_legacy.sql` no container `postgres-legado` com as escolhas legadas de S07, cada uma com um comentário dizendo que é deliberada e por quê.
2. Seed de 50k usuários e 80k contas. O PDF § 3.2 B.1 pede **três** grupos de tabelas: usuários, contas e **parâmetros de configuração de instituições parceiras** — esta terceira é a que alimenta o `dict_institutions` da etapa 11 e o ref-sync da 14. Sem ela, o Dictionary não tem origem real.
3. Induzir bloat em 5 rodadas de `UPDATE`/`DELETE` conforme S07 § Volume e Bloat proposital. Declarar abertamente no doc que o bloat é induzido — é preciso ter um problema real para o dashboard da etapa 15 mostrar.
4. Medir o bloat (`pg_stat_user_tables`, razão de páginas mortas) e registrar o número.
5. Escrever as 2 queries complexas de S07 § As duas queries complexas, capturar `EXPLAIN (ANALYZE, BUFFERS)` antes, otimizar, capturar depois — mesmo ritual de medição da etapa 06 (descartar 1ª, mediana de 3).
6. Escrever `desafio-1/migration-analysis.md` (1 página): inventário, estratégia de cutover, critérios de custo/performance/HA, e o que muda ao sair de PostgreSQL autogerenciado para Aurora.
7. Acrescentar o bloco `# --- 10 legado-e-migracao-aurora ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] Schema legado criado no `postgres-legado`, com `SERIAL`/`TIMESTAMP`/`VARCHAR` e comentário de que é deliberado
- [ ] 50.000 usuários e 80.000 contas carregados
- [ ] Tabela de parâmetros de configuração de instituições parceiras existe e está populada (origem do Dictionary)
- [ ] Bloat induzido em 5 rodadas e **medido** com número real
- [ ] As 2 queries têm `EXPLAIN` antes e depois, com tempo mediano de 3
- [ ] `migration-analysis.md` cabe em 1 página e cobre custo, performance, HA e esforço operacional
- [ ] Nenhum recurso AWS foi provisionado — só documento

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 10.1 | compose | `psql -h legado -c "SELECT count(*) FROM users"` | `50000` |
| 10.2 | compose | `psql -h legado -c "SELECT count(*) FROM accounts"` | `80000` |
| 10.3 | compose | `psql -h legado -c "SELECT n_dead_tup FROM pg_stat_user_tables WHERE relname='accounts'"` | > 0 (bloat presente) |
| 10.7 | compose | `psql -h legado -c "SELECT count(*) FROM institution_config"` | > 0 (origem do Dictionary) |
| 10.4 | local | `ls desafio-1/queries/explains/legacy_q{1,2}_{before,after}.txt` | 4 arquivos |
| 10.5 | local | `test -f desafio-1/migration-analysis.md` | sai 0 |
| 10.6 | local | `! grep -rqi 'aws configure\|terraform apply\|boto3' desafio-1/migration-analysis.md` | sai 0 (nada executado) |

## ROLLBACK
```bash
docker compose exec -T postgres-legado psql -U trio -d legado -c "
DROP TABLE IF EXISTS accounts CASCADE;
DROP TABLE IF EXISTS users CASCADE;"
git checkout -- desafio-1/schemas/02_legacy.sql desafio-1/migration-analysis.md
```

## STATUS
Estado: PENDENTE
Premissas assumidas: —
Desvios do plano: —

## FECHAMENTO
- [ ] Critérios atendidos
- [ ] Testes no run_all.sh
- [ ] run_all.sh sem FAIL
- [ ] ESTADO HERDADO da próxima preenchido
- [ ] Bloco no LOG-EXECUCAO.md
- [ ] Desvio? → atualizar 99-validacao-final.md
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
