# 06 — QUERIES ANTES DOS ÍNDICES  [carga-real]

## ORIGEM
`../vault-estudo/06-Especificacao/S06-Indices-e-Queries.md` § O método · § Q1 — Versão ingênua · § Q2 — Versão ingênua · § Q3 — Versão ingênua · § Q4 — Versão ingênua (self-join, o anti-padrão)

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído

## ESTADO HERDADO
Verificado ao fechar a etapa 05:
- Dataset real de 10M carregado no volume `trio-data-challenge_timescaledb_data`: `transactions` 10.000.000 linhas, `accounts` 500.000, `reconciliation_events` 1.442.199 (~14,4%, dentro da tolerância de S02). 338 chunks em `transactions` (dias sem transação sorteada não geram chunk — dentro do "~365" esperado).
- Distribuições confirmadas: tipo (pix 60,02% | card 21,99% | ted 9,99% | boleto 8,00%), status (settled 95,68% | failed 3,66% | reversed 0,50% | pending 0,17% — pending concentrado nas últimas 48h reais), instituição líder 001/BB com 33,55% (Zipf funcionando), latência de liquidação por tipo dentro dos P50/P95 de S02.
- **Nenhum índice além do implícito de PK** em `transactions` (confirmado: só `transactions_pkey` + `transactions_created_at_idx` da hypertable). Nenhum CAgg, nenhuma política. Esta é exatamente a pré-condição que a etapa 06 precisa para medir o "antes" honesto.
- `ANALYZE` já rodado ao final do seed (`last_analyze` preenchido em `transactions`) — estatísticas do planejador estão atualizadas, então os `EXPLAIN` desta etapa refletem plano real, não estimativa desatualizada.
- `seed_control.finished_at` preenchido — `make seed`/`docker compose run --rm seed` daqui pra frente é no-op até `--force`.
- Gerador em `desafio-1/seed/` (`generate_transactions.py`, `distributions.py`, `accounts.py`, `config.py`, `Dockerfile`) funcional e testado; **não mexer** — não é escopo desta etapa.
- Bugs corrigidos durante a 05 (documentados em STATUS): `COPY BINARY` exige `Decimal` (não `float`) para `NUMERIC` e `copy.set_types()` explícito para `CHAR(3)`/ENUMs registrados; timestamps do mês corrente precisam ser clipados em "agora" para não gerar dado no futuro.
- Ficha `DOCKER-LOCAL.md`: seed concluído em 1m57s (bem abaixo do ~20min de S02 — máquina local performou acima do esperado apesar dos 8.3GB de RAM, não 32GB).
- `run_all.sh`: blocos 01-05, 29 pass / 0 fail / 4 skip. `audit.sh` mantém os FAILs conhecidos de `concluidas/` (A2.1/.01/.02/.03/.04, não bloqueia) + novo WARN A6.2 (script de auditoria não distingue "antes da etapa 01" de "depois", código do seed é esperado agora — não é regressão).
- Containers de pé no momento do fechamento: `timescaledb` e `postgres-legado` (healthy). `clickhouse`/`grafana`/demais do perfil full não estão rodando.

## ESCOPO
Faz: escrever Q1–Q4 na versão ingênua, executar cada uma com `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` sobre os 10M **sem nenhuma otimização**, e capturar a saída em `desafio-1/queries/explains/qN_before.txt`.
Não faz: **não cria índice nenhum, não cria CAgg nenhum, não otimiza nenhuma query.** O valor desta etapa é exatamente o baseline sem otimização — é o "antes" honesto que o desafio cobra. Otimizar aqui apagaria a evidência que as etapas 07 e 08 precisam comparar. Esta é a inversão deliberada de S06-antes-de-S03 registrada em `ESPECIFICACAO.md`.

## PASSOS
1. Ler S06 § O método e seguir o ritual sem atalho.
2. Escrever Q1 (volume e valor por tipo e status, por mês, últimos 6 meses) na versão ingênua de S06.
3. Escrever Q2 (divergências de reconciliação > R$ 0,01, últimos 30 dias, com contas) na versão ingênua.
4. Escrever Q3 na versão ingênua — o PDF § 3.2 A.6.c pede as **3 colunas**: top 20 instituições por volume transacionado em 90 dias, **com média de tempo de liquidação e taxa de falha**. Volume sozinho não atende o requisito.
5. Escrever Q4 (detecção de duplicatas em janela de 5 min) na versão ingênua com self-join — o anti-padrão, deliberado, comentado como tal.
6. Para cada query: executar 4 vezes, **descartar a 1ª**, registrar a **mediana das 3 restantes**, e salvar o `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` em `desafio-1/queries/explains/qN_before.txt` com `Buffers: shared hit` vs `read` visível.
7. Anotar os 4 tempos medianos em `desafio-1/queries/MEDICOES.md` (a tabela consolidada do `REPORT.md` é a etapa 07).
8. Acrescentar o bloco `# --- 06 queries-antes-indices ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] `q1_before.txt` … `q4_before.txt` existem e contêm `Buffers:` com `shared hit` e `read`
- [ ] Cada arquivo contém `EXPLAIN` com `ANALYZE`, `BUFFERS` e `VERBOSE`
- [ ] Tempo registrado é mediana de 3 execuções, com a 1ª descartada — declarado no arquivo
- [ ] `pg_indexes` sobre `transactions` continua sem índice além do implícito de PK
- [ ] Nenhum continuous aggregate existe ainda
- [ ] Q4 está na forma self-join, com comentário dizendo que é o anti-padrão medido de propósito
- [ ] Q3 devolve as 3 colunas do PDF: volume, média de tempo de liquidação e taxa de falha
- [ ] Q2 traz dados das contas de **origem e destino** (2 joins com `accounts`), conforme PDF § 3.2 A.6.b

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 06.1 | local | `ls desafio-1/queries/explains/q{1,2,3,4}_before.txt` | 4 arquivos |
| 06.2 | local | `grep -l 'Buffers:' desafio-1/queries/explains/*_before.txt \| wc -l` | 4 |
| 06.3 | carga-real | `psql -c "SELECT count(*) FROM pg_indexes WHERE tablename='transactions'"` | só o implícito de PK |
| 06.4 | carga-real | `psql -c "SELECT count(*) FROM timescaledb_information.continuous_aggregates"` | `0` |
| 06.5 | local | `grep -c 'mediana' desafio-1/queries/MEDICOES.md` | ≥ 1 |

## ROLLBACK
```bash
rm -rf desafio-1/queries/explains desafio-1/queries/MEDICOES.md
git checkout -- desafio-1/queries/
```

## STATUS
Estado: BLOQUEADA
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
