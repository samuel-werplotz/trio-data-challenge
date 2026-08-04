# 99 — VALIDAÇÃO FINAL  [carga-real]

## ORIGEM
PDF § 6.1 "Critérios de Aceitação Mínimos" + PDF § 7 "Apresentação Técnica"; `../vault-estudo/06-Especificacao/S10-Conformidade-PDF.md` (rastreio requisito-a-requisito — **conferir inteiro antes de entregar**); `../vault-estudo/06-Especificacao/ESPECIFICACAO.md` § Limitações assumidas e documentadas; `../vault-estudo/03-Fluxo-Desenvolvimento/E13-Apresentacao.md` § O teste do zero · § O README raiz · § As 5 perguntas

## IMPEDITIVOS
- [ ] ficha `scripts/ambiente/DOCKER-LOCAL.md` tem campo `<PREENCHER>` → preencher e confirmar seed concluído

## ESTADO HERDADO
<preenchido pela etapa 15 ao fechar>

## ESCOPO
Faz: sequência completa do zero cronometrada, README raiz com os tempos reais, `REPORT.md` consolidado, roteiro de demonstração e ensaio das 5 perguntas previstas.
Não faz: não corrige funcionalidade — o que quebrar aqui volta para a etapa dona do problema; não reescreve etapa já concluída.

## PASSOS
1. Rodar a sequência do zero, cronometrando cada passo: `nuke` → `up` → `seed` → `indexes` → `policies` → `backfill` → `pipeline` → `check`.
2. Preencher a coluna `evidência` da tabela dos 7 critérios abaixo com arquivo, comando ou número real.
3. Conferir o mapa requisito-do-PDF → arquivo-entregue, item a item.
4. Escrever o README raiz na ordem de E13: o que é (3 linhas) → como subir (1 comando) → quanto tempo cada passo leva → como verificar → mapa do repositório → link para cada documento.
5. Consolidar o `REPORT.md`: tabela antes/depois das queries, taxa de compressão, número do sub-segundo do ClickHouse, RTO/RPO medidos.
6. Escrever o roteiro de demonstração e ensaiar as 5 perguntas.
7. Rodar `run_all.sh` inteiro pela última vez.

## CRITÉRIOS DE ACEITE
- [ ] Sequência do zero completa sem intervenção manual, com tempo de cada passo registrado
- [ ] Os 7 critérios do PDF § 6.1 com evidência preenchida
- [ ] README raiz responde as 6 perguntas de E13
- [ ] `REPORT.md` sem número inventado — tudo medido
- [ ] `run_all.sh` sem nenhum `FAIL`
- [ ] As 5 limitações assumidas estão declaradas no repositório entregue

---

## Os 7 critérios de aceitação mínimos (PDF § 6.1)

| # | Critério (literal do PDF) | Etapa que entrega | Evidência |
|---|---|---|---|
| 1 | `docker-compose up -d` sobe todo o ambiente sem erros | 02, 03 | `<PREENCHER>` |
| 2 | Scripts de seed rodam e populam os bancos com volume relevante | 05, 10 | `<PREENCHER>` |
| 3 | Queries do Desafio 1 executam com sucesso e têm `EXPLAIN ANALYZE` documentado | 06, 07 | `<PREENCHER>` |
| 4 | Pelo menos um pipeline (TimescaleDB → ClickHouse) funciona end-to-end de forma demonstrável | 12, 13 | `<PREENCHER>` |
| 5 | Pelo menos um dashboard Grafana está funcional consultando ClickHouse | 15 | `<PREENCHER>` |
| 6 | Documentação cobre decisões técnicas com justificativas | 09, 14, 15 | `<PREENCHER>` |
| 7 | Análise de migração PostgreSQL → Aurora está presente e fundamentada | 10 | `<PREENCHER>` |

## Mapa requisito → arquivo entregue

| Desafio | Requisito | Arquivo |
|---|---|---|
| 1 | Schema TimescaleDB | `desafio-1/schemas/01_timescale_schema.sql`, `init/timescaledb/01_schema.sql` |
| 1 | Seed de volume relevante | `desafio-1/seed/generate_transactions.py` |
| 1 | Queries + `EXPLAIN` antes/depois | `desafio-1/queries/`, `desafio-1/queries/explains/qN_{before,after}.txt` |
| 1 | Índices | `init/timescaledb/03_indexes.sql` |
| 1 | CAggs, compressão, retenção | `init/timescaledb/04_caggs_policies.sql` |
| 1 | LGPD / sanitização de PII | `desafio-1/lgpd-sanitization.md` |
| 1 | Schema legado + bloat | `desafio-1/schemas/02_legacy.sql` |
| 1 | Migração para Aurora | `desafio-1/migration-analysis.md` |
| 1 | Consolidação de medições | `desafio-1/REPORT.md` |
| 2 | Schema ClickHouse (engine, MVs, Dictionary) | `init/clickhouse/01_schema.sql` |
| 2 | Pipeline CDC (conector + consumidor) | `desafio-2/pipeline/` |
| 2 | Ref-sync e API | `desafio-2/pipeline/ref_sync.py`, API FastAPI |
| 2 | Diagramas | `desafio-2/diagrams/` |
| 2 | Decisões arquiteturais | `desafio-2/ADR.md` |
| 3 | Backup dos **3** bancos (tipo, frequência, retenção, destino AWS) | `desafio-3/backup/`, `desafio-3/backup/README.md` |
| 3 | Recovery com perda simulada e 3 contagens | `scripts/restore-drill.sh` |
| 3 | Dashboards e alertas (métrica, threshold, severidade, ação, CloudWatch/SNS) | `desafio-3/grafana/`, `init/grafana/provisioning/` |
| 3 | Runbook do storage em 92% | `desafio-3/runbook.md` |
| 3 | Resposta a incidente SEV-1 | `desafio-3/incident-response.md` |
| — | Ambiente | `docker-compose.yml`, `Makefile`, `.env.example` |
| — | Apresentação | `README.md`, `docs/` |

## Limitações assumidas (declarar antes que perguntem)

| Limitação | Razão | Onde está documentada |
|---|---|---|
| Funil de status mede estado, não transição | A origem não guarda histórico de mudanças | S04 → `init/clickhouse/01_schema.sql`, `ADR.md` |
| `external_id` sem unicidade global | Índice único sobre 365 chunks é caro demais; unicidade é do sistema de origem | S01 → `01_schema.sql`, `REPORT.md` |
| Sem chave estrangeira em `transactions` | FK mataria a performance da carga de 10M; prática de alto volume | S01 → `01_schema.sql` |
| Plano B do CDC perde `DELETE` | Watermark por `updated_at` não captura exclusão | `ADR.md` (registrado mesmo se o plano B não for acionado) |
| Bloat do legado é induzido | Precisamos de um problema real para o dashboard mostrar — declarado abertamente | `migration-analysis.md`, dashboard do legado |

## Desvios do plano registrados durante a execução

| Etapa | Desvio | Razão | Resolução |
|---|---|---|---|
| 07 | Testes `04.6` e `06.3` do `run_all.sh` viraram obsoletos | Ambos afirmavam "nenhum índice além dos implícitos em `transactions`", verdadeiro nas etapas 04 e 06. A etapa 07 cria índices **por design** (é o objeto da etapa), então a asserção deixa de valer por avanço legítimo da esteira, não por regressão. | Reescritos para asserir a **pré-condição da própria etapa** em vez de um estado global: passam a exigir que o número de índices seja o esperado *naquele ponto do roadmap*, checando a ausência dos índices nomeados de `03_indexes.sql` em vez de contar o total. `qN_before.txt` continua sendo a evidência de que a medição "antes" foi feita sem índice. |
| 07 | `reconciliation_events` regerado (dado da etapa 05 substituído) | O gerador produzia divergência como percentual do valor (86% das linhas divergiam, não ~8%) e `reconciled_at = now()` para todas as linhas (filtro de 30 dias não excluía nada). As duas coisas invalidavam a premissa de seletividade do índice parcial de Q2 (S06) e o teste de exclusão de chunk. | `load_reconciliation()` corrigido; só `reconciliation_events` foi truncado e recarregado (os 10M de `transactions` intactos); medições de Q2 refeitas do zero — `before` (com índices removidos) e `after` — sobre o dado corrigido. Documentado em `desafio-1/REPORT.md` e `MEDICOES.md`. |

## As 5 perguntas previstas (PDF § 7)

1. **"E se o volume triplicasse, o que mudaria na arquitetura?"** — chunk menor no Timescale; mais partições e consumidores; shard no ClickHouse por instituição; compressão mais agressiva. O ponto: a fila no meio já permite escala horizontal sem mudar código.
2. **"Como adicionaria um novo consumer no ClickHouse sem impactar as aplicações existentes?"** — novo consumer group no mesmo tópico, com offset próprio. É justamente por isso que existe uma fila em vez de conexão direta.
3. **"Como faria a migração de engine de uma tabela ClickHouse em produção sem downtime?"** — tabela nova com a engine desejada → `INSERT SELECT` do histórico → MV escrevendo nas duas → validar contagens → `RENAME` atômico → remover a antiga após período de segurança.
4. **"Qual sua estratégia para onboardar um Data Champion novo?"** — dashboards com variáveis em vez de SQL do zero; views prontas com nomes de negócio; dicionário de dados; convenção de nomes; canal de dúvidas. Não se escala treinando um a um, escala-se reduzindo o que é preciso saber.
5. **"Migrar o legado para Aurora amanhã — plano de 72h?"** — h0-8 inventário · h8-16 Aurora provisionado, restore de snapshot, DMS em CDC · h16-40 validação (contagens, checksums, performance real) · h40-48 ensaio de cutover em ambiente espelho · h48-52 janela real (pausa escritas, lag zero, aponta aplicação) · h52-72 monitoramento com replicação reversa ativa para rollback.

> Duração da sessão: **30 a 45 minutos**, dito pelo PDF em § 2.1 e de novo em § 7. O `E13-Apresentacao.md` do vault já foi corrigido com o roteiro de 45 min e a ordem de corte para 30. O § 7 exige **4 blocos**: ambiente rodando, decisões arquiteturais, perguntas de aprofundamento e **discussão do cenário de incidente** — este último é fácil de esquecer no ensaio.

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 99.1 | carga-real | sequência `nuke`→`up`→`seed`→`indexes`→`policies`→`backfill`→`pipeline`→`check` | sai 0 ponta a ponta |
| 99.2 | carga-real | `bash scripts/tests/run_all.sh` | `0 fail` |
| 99.3 | local | `! grep '^| [1-7] |' scripts/roadmap/99-validacao-final.md \| grep -q 'PREENCHER'` | sai 0 (as 7 evidências preenchidas) |
| 99.4 | local | `! grep -q '<PREENCHER>' scripts/ambiente/DOCKER-LOCAL.md` | sai 0 |
| 99.5 | local | `test -f README.md -a -f desafio-1/REPORT.md` | sai 0 |
| 99.6 | compose | `make check` | sai 0 |

## ROLLBACK
```bash
git reset --hard <sha do checkpoint da etapa 15>
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
