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
Verificado ao fechar a etapa 15:
- **Observabilidade completa e de pé**: Prometheus em `:9090` com **7/7 alvos up** (3 workers Python + 2 pg-exporter + ClickHouse + self), 6 regras de alerta carregadas e `health=ok`. 4 dashboards provisionados no Grafana (`Trio · TimescaleDB`, `· ClickHouse`, `· Pipeline`, `· PostgreSQL Legado`), todos consultando dado real através das 3 datasources.
- **`init/prometheus/` deixou de estar vazio** — era por isso que o Prometheus reiniciava em loop desde a etapa 02. Agora tem `prometheus.yml` + `alert_rules.yml`.
- **ClickHouse ganhou `:9363/metrics`** via `init/clickhouse-config/prometheus.xml` (mesmo padrão de `config.d/` do `backup.xml`). Container recriado; **dado conferido antes e depois: 10.000.000 linhas intactas**.
- **Dashboards ficam em `init/grafana/dashboards/`, NÃO em `provisioning/dashboards/`** (que guarda só o `dashboards.yml`). Se os `.json` morarem junto do `.yml`, o Grafana tenta ler o próprio `.yml` como dashboard e não carrega nenhum — falha silenciosa, sem erro no log. Teste `15.15` guarda essa regressão.
- **Datasources agora têm UID fixo** (`trio-timescaledb`, `trio-legado`, `trio-clickhouse`, `trio-prometheus`): os dashboards referenciam por UID, e UID gerado aleatoriamente quebraria os painéis a cada recriação.
- **`desafio-3/runbook.md` e `desafio-3/incident-response.md` escritos**, com os comandos SQL verificados contra o banco real (156 chunks de 6+ meses, 1.111 MB, `cagg_watermark` funcionando como guarda). `desafio-3/grafana/alertas.md` documenta os 6 alertas com os 5 campos.
- **`E2.4` corrigido** — a condição virou dupla (idade **e** lag), igual ao alerta `PipelineParado`. A versão anterior falhava de forma sistemática com banco ocioso (medido: 1516s de idade com lag de 0,98s e worker íntegro). Não era defeito do worker.
- `run_all.sh`: blocos 01–15, **159 pass / 0 fail / 3 skip**. `audit.sh`: 83 pass / 0 fail / 2 warn / 1 skip.
- **Dataset intacto**: `transactions` com 10.000.000 linhas (teste `15.9`), `transactions_raw` com 10.000.000.
- **Insumo pronto para esta etapa**: o passo 4 (limitação do funil de status) já tem lugar reservado — o `ADR.md` da etapa 14 declara a limitação do `DELETE`, e o mesmo padrão de "declarar antes que perguntem" se aplica ao funil.

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
- [x] P95 **e** P99 de latência por instituição/dia disponíveis, com o caminho usado documentado — `v_settlement_latency_percentiles` já entregava; saída real no `REPORT.md` e motivo do caminho alternativo (`percentile_cont`, sem toolkit). Testes `16.1`/`16.2`
- [x] `REPORT.md` declara as duas retenções, o motivo do `scheduled=false` e o comando que habilita — `alter_job(1007, scheduled => true)`, job conferido no banco. Teste `16.3`
- [x] `migration-analysis.md` cobre os 4 sub-itens do PDF § 3.2 B.3 — 60 → **210 linhas**, uma seção por sub-item. Testes `16.4`/`16.5`
- [x] Limitação do funil de status declarada no `REPORT.md` e no `ADR.md` — teste `16.7`
- [x] Texto "Dictionary vs JOIN" existe, com número medido dos dois caminhos — **0,018s × 0,054s (2,9×)** no lookup por linha; empate em `GROUP BY` reportado também. Testes `16.6`/`16.9`
- [x] Procedimento LGPD no ClickHouse **executado**, não descrito como futuro — testes `16.8`/`16.10`
- [x] Matriz da auditoria § FASE 3 sem nenhuma linha em FALTA — teste `16.11`; critérios do PDF § 6.1 passaram de 2/7 para **7/7**
- [x] Toda linha que permanecer PARCIAL tem justificativa escrita do porquê — só **C2b** permanece, justificada

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
Estado: CONCLUÍDA

Premissas assumidas:
- **A4b e A5 já estavam atendidos no produto**, não no texto. A view de percentis já entregava P95 e P99 por instituição/dia, e as 3 políticas de retenção já existiam com a justificativa correta. O gap era documental — o PDF avalia o que está escrito, e o que não está documentado não conta.
- **C2b permanece PARCIAL, por decisão.** Medir transição de status exigiria tabela de eventos append-only na **origem** — mudança no sistema transacional de pagamentos, que a Seção 2 põe fora do escopo e que não é decisão da camada analítica. A entrega é a limitação declarada nos dois documentos, com o caminho descrito.
- **Dictionary vs JOIN medido em 3 padrões de uso, não em um.** Reportar só o lookup por linha (onde o Dictionary ganha 2,9×) seria escolher o cenário favorável; o empate em `GROUP BY` está na mesma tabela.
- **LGPD verificado pela ausência.** A prova de que não há PII no ClickHouse é uma varredura de `system.columns` que devolve zero colunas de dado pessoal, mais o teste de propagação com conta sintética. Verificação negativa é evidência quando a busca é exaustiva.

Desvios do plano:
1. **O passo 6 inverteu a conclusão do documento original.** A etapa 09 descreveu a propagação do apagamento ao ClickHouse como procedimento a executar quando o CH existisse. Executado, o resultado foi que **não há propagação a fazer**: `accounts_dim` nunca foi criada e `transactions_raw` referencia o titular só por `source_account_id`. O passo foi reescrito como verificação (com evidência) em vez de procedimento, e o procedimento hipotético ficou registrado para o caso de uma dimensão com PII ser materializada no futuro.
2. **A matriz da auditoria foi reescrita, não só conferida.** O `PASSO 7` pedia conferir; a matriz estava desatualizada em **21 linhas** — era o retrato do momento da auditoria, quando as etapas 13.5–16 não existiam. Cada linha foi reconferida **contra o ambiente rodando** (containers de pé, backup, demo de mutação reexecutada) e atualizada. Os critérios do PDF § 6.1 passaram de 2/7 para 7/7.
3. **Teste `12.6` quebrou durante a etapa e expôs uma armadilha real.** O `ALTER TABLE ... DELETE` que removeu a transação sintética da `transactions_raw` **não removeu o agregado correspondente nas 2 MVs** — MV no ClickHouse é gatilho de inserção, não view materializada que recalcula. Raw voltou a 10.000.000 e as MVs ficaram em 10.000.001. Corrigido removendo e reconstruindo apenas a fatia divergente (`2026-08-04`/`001`/`pix`) a partir da raw. **É a mesma classe de armadilha da etapa 12** (lá o `INSERT SELECT` duplicou o que a MV já havia capturado): mexer na raw sem tratar a MV deixa as duas fora de sincronia, nos dois sentidos.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (bloco `# --- 16 fechamento-de-lacunas-do-pdf ---`, 12 testes)
- [x] run_all.sh sem FAIL — 171 pass, 0 fail, 3 skip
- [x] ESTADO HERDADO da próxima preenchido (99)
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → registrado em `99-validacao-final.md`
- [x] Commit checkpoint
- [x] Mover pra concluidas/. Marcar [x] no CLAUDE.md
