# 16 — FECHAMENTO DE LACUNAS DO PDF  [compose]

> **Etapa criada na reconciliação da esteira.** Existe porque a matriz de
> rastreabilidade da auditoria (`AUDITORIA-E-REPLANEJAMENTO.md` § FASE 3) lista
> requisitos marcados **PARCIAL** que nenhuma etapa do roadmap cobre — eles
> cairiam entre as cadeiras e a entrega ficaria incompleta. O requisito é 100%
> do PDF, não 100% do roadmap.

## ORIGEM
`AUDITORIA-E-REPLANEJAMENTO.md` § FASE 3 (matriz de rastreabilidade, linhas PARCIAL); PDF § 3.2 A.4b, A.5, B.3, C.2b, C.3; `../vault-estudo/06-Especificacao/S10-Conformidade-PDF.md` (rastreio requisito a requisito — **conferir inteiro antes de fechar**)

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
<preenchido pela etapa 15 ao fechar>

## ESCOPO
Faz: fecha os 5 requisitos que existem mas não atendem o texto integral do PDF — P95/P99 de latência (A4b), retenção declarada (A5), análise Aurora expandida (B3), limitação do funil de status (C2b) e o texto "Dictionary vs JOIN" (C3). Fecha também o passo do ClickHouse no procedimento LGPD, que ficou documentado como futuro na etapa 09 e hoje é executável.
Não faz: não reabre decisão de arquitetura; não refaz medição já registrada no `REPORT.md`.

## PASSOS
1. **A4b — P95/P99 por instituição (requisito literal).** O CAgg de latência usa `percentile_cont` em view porque o `timescaledb_toolkit` não existe na imagem fixada. Verificar se a view entrega P95 **e** P99 por instituição por dia; se entregar, documentar no `REPORT.md` que o requisito está atendido por caminho alternativo, com o motivo. Se não entregar, completar a view.
2. **A5 — retenção.** A política de retenção existe e está **desabilitada** (`scheduled=false`), por conflito entre os 90 dias do requisito e o dataset de 12 meses. Escrever no `REPORT.md`: as duas retenções (90d raw, 2 anos CAgg), por que está desabilitada, e o comando exato que a habilita. `retention-demo.sh` já demonstra o efeito.
3. **B3 — análise Aurora.** `desafio-1/migration-analysis.md` tem 60 linhas para um requisito de "1 página" com 4 sub-itens. Expandir cobrindo explicitamente: (a) EC2 vs Aurora vs RDS com custo/performance/HA/overhead operacional; (b) estratégia de migração (DMS, replicação lógica, blue-green); (c) riscos e mitigações; (d) plano de rollback.
4. **C2b — funil de status.** A MV `mv_status_funnel` mede estado atual, não transição, porque a origem não guarda histórico de mudanças. Declarar a limitação no `REPORT.md` e no `ADR.md` — é limitação assumida, e declarar antes que perguntem vale mais do que ser perguntado.
5. **C3 — Dictionary vs JOIN.** O `dict_institutions` existe e resolve dado real, mas falta o **texto** que o PDF pede: quando e por que preferir Dictionary a uma JOIN. Escrever com o número real de latência do `dictGet` medido contra a JOIN equivalente.
6. **LGPD no ClickHouse.** A etapa 09 documentou o passo de propagação como "futuro" porque o ClickHouse ainda não existia. Hoje existe: executar o procedimento de ponta a ponta e trocar o texto de "futuro" por evidência real.
7. Conferir `S10-Conformidade-PDF.md` inteiro, item a item, e a matriz da auditoria — nenhuma linha pode ficar em FALTA ou PARCIAL sem justificativa escrita.
8. Acrescentar o bloco `# --- 16 fechamento-de-lacunas-do-pdf ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] P95 **e** P99 de latência por instituição/dia disponíveis, com o caminho usado documentado
- [ ] `REPORT.md` declara as duas retenções, o motivo do `scheduled=false` e o comando que habilita
- [ ] `migration-analysis.md` cobre os 4 sub-itens do PDF § 3.2 B.3
- [ ] Limitação do funil de status declarada no `REPORT.md` e no `ADR.md`
- [ ] Texto "Dictionary vs JOIN" existe, com número medido dos dois caminhos
- [ ] Procedimento LGPD no ClickHouse **executado**, não descrito como futuro
- [ ] Matriz da auditoria § FASE 3 sem nenhuma linha em FALTA
- [ ] Toda linha que permanecer PARCIAL tem justificativa escrita do porquê

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 16.1 | carga-real | query de P95/P99 por instituição | devolve as 2 colunas, sem erro |
| 16.2 | local | `grep -ci 'p99' desafio-1/REPORT.md` | ≥ 1 |
| 16.3 | local | `grep -ci 'scheduled.*false\|desabilitada' desafio-1/REPORT.md` | ≥ 1 |
| 16.4 | local | `wc -l < desafio-1/migration-analysis.md` | ≥ 120 (1 página real, 4 sub-itens) |
| 16.5 | local | `grep -ci 'rollback' desafio-1/migration-analysis.md` | ≥ 1 |
| 16.6 | local | `grep -ci 'dictionary' desafio-1/REPORT.md desafio-2/ADR.md` | ≥ 1 |
| 16.7 | local | `grep -ci 'transição\|limitação' desafio-1/REPORT.md` | ≥ 1 (funil de status) |
| 16.8 | local | `! grep -qi 'procedimento futuro\|não executado' desafio-1/lgpd-sanitization.md` | sai 0 |

## ROLLBACK
```bash
git checkout -- desafio-1/REPORT.md desafio-1/migration-analysis.md desafio-1/lgpd-sanitization.md desafio-2/ADR.md
```
> Etapa majoritariamente documental; a única execução é o procedimento LGPD, que roda sobre conta sintética descartável.

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
