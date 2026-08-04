# 07 — ÍNDICES E OTIMIZAÇÃO  [carga-real]

## ORIGEM
`../vault-estudo/06-Especificacao/S06-Indices-e-Queries.md` § Q2 Índices · § Por que índice parcial · § Por que `INCLUDE` no segundo · § Q3 Índice · § Q4 Versão otimizada (window function) · § Q4 Índice de apoio · § Query bônus — gapfill de 48h · § Tabela consolidada do REPORT.md

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído

## ESTADO HERDADO
<preenchido pela etapa 06 ao fechar>

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
- [ ] `03_indexes.sql` existe e cria os índices de S06, cada um comentado com o porquê
- [ ] `q1_after.txt` … `q4_after.txt` existem com `Buffers:` visível
- [ ] Todo `qN_before.txt` continua intacto (mesmo conteúdo da etapa 06)
- [ ] Q4 otimizada usa window function, sem self-join
- [ ] Query de gapfill devolve 48 buckets horários contínuos, sem buraco
- [ ] `REPORT.md` tem a tabela antes/depois com tempo mediano e buffers reais das 4 queries
- [ ] O índice que não melhorou aparece na tabela com a justificativa
- [ ] Cada tempo "depois" é mediana de 3 com a 1ª descartada

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
