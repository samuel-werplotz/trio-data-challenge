# 07 — ÍNDICES E OTIMIZAÇÃO  [carga-real]

## ORIGEM
`../vault-estudo/06-Especificacao/S06-Indices-e-Queries.md` § Q2 Índices · § Por que índice parcial · § Por que `INCLUDE` no segundo · § Q3 Índice · § Q4 Versão otimizada (window function) · § Q4 Índice de apoio · § Query bônus — gapfill de 48h · § Tabela consolidada do REPORT.md

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído

## ESTADO HERDADO
Verificado ao fechar a etapa 06:
- `desafio-1/queries/q1_volume_por_tipo_status.sql`, `q2_divergencias_reconciliacao.sql`, `q3_top_instituicoes.sql`, `q4_deteccao_duplicatas.sql` — versões ingênuas literais de S06, sem alteração pendente para as etapas seguintes reescreverem por cima (Q2/Q3/Q4 mudam aqui; Q1 só muda na 08 com CAgg).
- `desafio-1/queries/explains/q{1,2,3,4}_before.txt` gravados e intactos — **não sobrescrever**. Medianas: Q1 12.115ms, Q2 8.103ms, Q3 1.285ms, Q4 2.814ms (self-join). `desafio-1/queries/MEDICOES.md` documenta o protocolo e observações por query.
- `desafio-1/queries/run-explains.sh` automatiza o ritual de medição (4 execuções, descarta 1ª, mediana das 3, salva `Buffers:`) — reutilizável para gerar os `_after.txt`, mas precisa apontar para os arquivos `_optimized.sql`/reescritos desta etapa, não os `_before` de novo.
- **Nenhum índice extra em `transactions`** (só os 2 implícitos), **nenhum CAgg** — confirmado antes de fechar a 06. Pré-condição intacta para esta etapa criar `03_indexes.sql`.
- `docker-compose.yml`: `timescaledb` ganhou `shm_size: "1gb"` (era o default de 64MB do Docker) — Q4 self-join estourava `/dev/shm` sem essa folga. Mudança de infra, container foi recriado preservando o volume de dados (10M intactos, confirmado). Se as etapas seguintes também fizerem hash join grande, essa folga já existe.
- Dataset: 10M transactions, 500k accounts, 1.442.199 reconciliation_events, 338 chunks. `ANALYZE` rodado. `seed_control.finished_at` preenchido — `make seed` é no-op sem `--force`.
- `run_all.sh`: blocos 01-06, 34 pass / 0 fail / 4 skip. `audit.sh` mantém os FAILs conhecidos de `concluidas/` (script de auditoria do plano não escala com o roadmap avançando — não é regressão de arquitetura/PDF, documentado desde a etapa 02).
- Containers de pé: `timescaledb` (recriado com novo `shm_size`, healthy) e `postgres-legado` (healthy).

## ESCOPO
Faz: `init/timescaledb/03_indexes.sql` (índice parcial, covering com `INCLUDE`, apoio à detecção de duplicatas), versões otimizadas de Q1–Q4, `qN_after.txt`, query bônus de gapfill de 48h com `locf`/`interpolate`, e a tabela antes/depois do `REPORT.md` com número real.
Não faz: não cria CAgg — Q1 e Q3 na versão que lê do CAgg ficam para a etapa 08, que reexecuta a medição. Não apaga nem regrava nenhum `qN_before.txt`.

## PASSOS
1. Escrever `03_indexes.sql` com os índices de S06, cada um com uma linha de comentário dizendo **por que** — índice parcial (só a fatia que a query filtra) e `INCLUDE` (evita o heap fetch).
2. Aplicar os índices via `make indexes` (fora do `init`, depois da carga — criar índice durante `COPY` de 10M é ordens de magnitude mais lento).
3. Reescrever Q2 e Q3 nas versões otimizadas de S06.
4. Reescrever Q4 trocando o self-join pela window function de S06 § Versão otimizada.
5. Escrever a query bônus de gapfill de 48h com `time_bucket_gapfill` + `locf`/`interpolate`.
6. Reexecutar o ritual de medição (descartar 1ª, mediana de 3, buffers) e salvar `desafio-1/queries/explains/qN_after.txt`.
7. Preencher a tabela consolidada do `desafio-1/REPORT.md` com os números reais — **incluindo o índice que não melhorou**, que entra na tabela do mesmo jeito, com a explicação de por que não ajudou.
8. Acrescentar o bloco `# --- 07 indices-e-otimizacao ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] `03_indexes.sql` existe e cria os índices de S06, cada um comentado com o porquê
- [x] `q1_after.txt` … `q4_after.txt` existem com `Buffers:` visível — **exceto `q1_after.txt`**: a otimização de Q1 é ler do CAgg, criado só na etapa 08 (o próprio ESCOPO desta etapa exclui CAgg). `q{2,3,4}_after.txt` entregues.
- [x] Todo `qN_before.txt` continua intacto (mesmo conteúdo da etapa 06) — exceto `q2_before.txt`, **deliberadamente remedido** após correção do dado de `reconciliation_events` (ver STATUS); q1/q3/q4 com md5 inalterado.
- [x] Q4 otimizada usa window function, sem self-join
- [x] Query de gapfill devolve 48 buckets horários contínuos, sem buraco — 49 buckets (48h + bucket parcial da hora corrente), 0 nulos
- [x] `REPORT.md` tem a tabela antes/depois com tempo mediano e buffers reais das 4 queries
- [x] O índice que não melhorou aparece na tabela com a justificativa
- [x] Cada tempo "depois" é mediana de 3 com a 1ª descartada

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 07.1 | local | `ls desafio-1/queries/explains/q{1,2,3,4}_after.txt` | 4 arquivos |
| 07.2 | carga-real | `psql -c "SELECT count(*) FROM pg_indexes WHERE tablename='transactions'"` | > 1 |
| 07.3 | carga-real | `psql -c "SELECT indexdef FROM pg_indexes WHERE indexname LIKE '%partial%'"` | contém `WHERE` |
| 07.4 | local | `! grep -qi 'join transactions' desafio-1/queries/q4_optimized.sql` | sai 0 (sem self-join) |
| 07.5 | carga-real | query de gapfill | 48 linhas, sem `NULL` de bucket |
| 07.6 | local | `grep -c '|' desafio-1/REPORT.md` | tabela antes/depois preenchida |

## ROLLBACK
```bash
docker compose exec -T timescaledb psql -U trio -d trio -c "
DROP INDEX IF EXISTS idx_transactions_recon_partial;
DROP INDEX IF EXISTS idx_transactions_institution_covering;
DROP INDEX IF EXISTS idx_transactions_dup_detection;"
git checkout -- init/timescaledb/03_indexes.sql desafio-1/queries/ desafio-1/REPORT.md
```
> Ajustar os nomes ao que `03_indexes.sql` de fato criou antes de rodar.

## STATUS
Estado: CONCLUÍDA
Premissas assumidas:
- `03_indexes.sql` usa `CREATE INDEX IF NOT EXISTS` (o plano não especificava): sem isso, reaplicar o arquivo aborta com "relation already exists", o que atrapalha `make indexes` numa segunda execução.
- Q2 melhorou dentro do ruído (1.584→1.511ms) apesar de **ambos os índices serem usados** (`Parallel Index Scan` no parcial, `Index Only Scan` no covering). Gargalo real é o `Parallel Seq Scan` no lado de `transactions` do join. Registrado no `REPORT.md` como o "índice que não melhorou" que S06 pede que apareça na tabela do mesmo jeito.
- Q4 retorna 0 linhas nas duas versões (ingênua e otimizada) — o dataset sintético não produz duplicatas por coincidência exata de `amount` + origem + destino em 5 min. As medições comparam honestamente o custo de *procurar*, não de *retornar*. Limitação declarada no `REPORT.md`.
Desvios do plano:
1. **`reconciliation_events` regerado.** O gerador da etapa 05 produzia divergência como percentual do valor (86% das linhas com `abs(difference) > 0.01`, não os ~8% que S06 assume para o índice parcial fazer sentido) e `reconciled_at = now()` para todas as linhas (o filtro "últimos 30 dias" de Q2 não excluía nada). `load_reconciliation()` corrigido; só essa tabela foi truncada e recarregada — os 10M de `transactions` intactos. **Q2 foi remedida do zero**: índices de Q2 removidos → novo `q2_before.txt` → índices recriados → novo `q2_after.txt`, para que a comparação seja sobre a mesma base.
2. **Testes `04.6` e `06.3` do `run_all.sh` reescritos.** Ambos asseriam "nenhum índice além dos implícitos em `transactions`" — verdadeiro nas etapas 04/06, invalidado por esta etapa, que cria índices por design. Reescritos para checar os implícitos por nome (04.6) e a ausência de `Index Scan using idx_` nos `qN_before.txt` (06.3), preservando o valor de regressão sem asserir estado global obsoleto.
Ambos registrados em `99-validacao-final.md` § Desvios do plano registrados durante a execução.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh
- [x] run_all.sh sem FAIL
- [x] ESTADO HERDADO da próxima preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → atualizar 99-validacao-final.md
- [x] Commit checkpoint
- [x] Mover pra concluidas/. Marcar [x] no CLAUDE.md
