# 14 — REF-SYNC, API E ADR  [compose]

## ORIGEM
`../vault-estudo/03-Fluxo-Desenvolvimento/E09-RefSync-ADR.md` § Parte B — O pipeline de referência · § Por que batch e não CDC · § A pergunta sobre Aurora · § Parte C — Diagrama e ADR; `../vault-estudo/02-Infraestrutura/Container-Ref-Sync.md`; `../vault-estudo/02-Infraestrutura/Container-API.md`; `../vault-estudo/06-Especificacao/S05-Pipeline-CDC.md` (contrato do consumidor, reaproveitado no ref-sync)

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado ao abrir a etapa 14 (a 13 foi DESCARTADA; o estado real vem da 13.5):
- `sync-worker` de pé em `:8001`, pipeline principal por micro-batch/watermark. CDC preservado só como artefato no profile `cdc-experimento`.
- ClickHouse com `transactions_raw` (10M), 2 MVs agregadas e `dict_institutions` já `LOADED` — a origem do Dictionary é `partner_institutions` no legado, que esta etapa passa a sincronizar ativamente.
- `ref-sync` e `api` existiam no `docker-compose.yml` só como esqueleto, no profile `pendente`, sem Dockerfile — implementá-los é exatamente o escopo desta etapa.
- Backup/restore entregues (pgBackRest → MinIO, `BACKUP` nativo do ClickHouse).
- `run_all.sh`: 118 pass / 0 fail / 3 skip.

## ESCOPO
Faz: `ref_sync.py` (batch de 5 min, legado → `dict_institutions`), a API FastAPI com os 3 endpoints (pool de conexão, cache de 10s, `query_ms` na resposta, timeout), os diagramas Mermaid em `desafio-2/diagrams/`, e `desafio-2/ADR.md` respondendo as 4 perguntas do desafio.
Não faz: **não usa CDC no legado** — a decisão travada é batch de 5 min; não altera o pipeline principal da etapa 13.

## PASSOS
1. Escrever `ref_sync.py`: lê o legado a cada 5 min e atualiza a fonte do `dict_institutions`. Comentar no cabeçalho por que é batch e não CDC (E09 § Por que batch e não CDC): dado de referência muda pouco, e um slot de replicação a mais no legado é custo operacional sem retorno.
2. Escrever a API FastAPI com os 3 endpoints de `Container-API.md`.
3. Implementar pool de conexão, cache de 10s, `query_ms` no corpo da resposta e timeout — cada um com comentário de intenção.
4. Desenhar os diagramas Mermaid em `desafio-2/diagrams/`. O PDF § 4.2 C.1 exige 4 coisas no diagrama de arquitetura, não só as caixas: **(a)** todos os componentes, incluindo **Hex** e as aplicações consumidoras, além de Timescale/PG-Aurora/ClickHouse/pipelines/filas/Grafana; **(b)** os **serviços AWS** envolvidos (VPC, subnets, S3 para backups, CloudWatch); **(c)** direção dos fluxos **e SLAs esperados** (latência, freshness); **(d)** **pontos de falha e estratégias de mitigação**.
5. Escrever `desafio-2/ADR.md` (1–2 páginas) respondendo as **4 perguntas literais** do PDF § 4.2 C.2: por que não um ETL tradicional? Como escalar se o volume 10x? Onde entra o legado PostgreSQL/Aurora nessa evolução? Quais serviços AWS alavancaria para resiliência e escala? Refletir **o que de fato aconteceu** com o CDC, não o plano original.
6. Registrar no ADR a limitação do plano B (perde `DELETE`), mesmo que o plano B não tenha sido acionado.
7. Responder por escrito, conforme PDF § 4.2 B.2, como o **ref-sync se comportaria numa migração para Aurora**: o que mudaria, o que precisaria ser adaptado, e se o pipeline sobreviveria sem alterações. Vai em `ADR.md` ou em doc próprio linkado.
8. Acrescentar o bloco `# --- 14 ref-sync-api-e-adr ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] `ref_sync.py` roda em ciclo de 5 min e uma mudança no legado aparece no Dictionary no ciclo seguinte — provado em **laço vivo** (ciclos `unchanged` → UPDATE no meio do laço → `reloaded` com frescor de 1s), não só por restart. Teste `14.4`
- [x] Os 3 endpoints respondem 200 com corpo válido — teste `14.1`
- [x] Toda resposta traz `query_ms` — teste `14.2`
- [x] Cache de 10s comprovado: 2ª chamada idêntica tem `query_ms` menor — 159,8 ms → 0,009 ms (~17.000×). Testes `14.3` e `14.15`
- [x] Timeout configurado e testado — `max_execution_time=5`; abortado **no servidor** (`Code: 159 Timeout exceeded: elapsed 5.000s`), confirmado em `system.query_log`, não só estouro de socket do cliente
- [x] Diagramas Mermaid renderizam sem erro de sintaxe — validado com `minlag/mermaid-cli` nos 3 arquivos
- [x] Diagrama de arquitetura mostra serviços AWS (VPC, subnets, S3, CloudWatch), **SLAs** de latência/freshness e **pontos de falha com mitigação** — testes `14.9`/`14.10`/`14.11`; falhas em `03-pontos-de-falha.mmd` (7 cenários)
- [x] Diagrama inclui Hex e as aplicações consumidoras, além de Grafana — teste `14.12`
- [x] `ADR.md` responde as 4 perguntas literais do PDF § 4.2 C.2 e registra a limitação do `DELETE` — testes `14.6`/`14.7`
- [x] Comportamento do ref-sync sob migração para Aurora respondido por escrito (PDF § 4.2 B.2) — teste `14.8`

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 14.1 | compose | `curl -s -o /dev/null -w '%{http_code}' localhost:8000/<ep1>` | `200` |
| 14.2 | compose | `curl -s localhost:8000/<ep1> \| jq -e '.query_ms'` | número presente |
| 14.3 | compose | 2 chamadas seguidas ao mesmo endpoint | 2º `query_ms` menor (cache) |
| 14.4 | compose | `UPDATE` no legado + esperar 1 ciclo + `dictGet` | valor novo |
| 14.5 | local | `test -d desafio-2/diagrams && ls desafio-2/diagrams/*.mmd` | ≥ 2 arquivos |
| 14.6 | local | `grep -c '^##' desafio-2/ADR.md` | ≥ 4 (as 4 perguntas) |

## ROLLBACK
```bash
docker compose stop ref-sync api
git checkout -- desafio-2/pipeline/ref_sync.py desafio-2/ADR.md desafio-2/diagrams/
```

## STATUS
Estado: CONCLUÍDA

Premissas assumidas:
- **Só `dict_institutions` é sincronizado.** `Container-Ref-Sync.md` cita também `dict_institution_config`, mas esse Dictionary **não existe** no schema de S04 e criá-lo seria mudança de schema — matéria travada pela Seção 5. O worker é parametrizado por `REF_DICTIONARY`/`REF_SOURCE_TABLE`, então acrescentá-lo depois é configuração, não reescrita.
- Detecção de mudança pelo par `(count(*), max(updated_at))`, não só `max(updated_at)`: sozinho, o máximo não se move num `DELETE`. O par cobre INSERT, UPDATE e DELETE.
- Janela dos endpoints ancorada em `max(created_at)` do dado, não em `now()`: o dataset é histórico e ancorar em `now()` devolveria vazio, escondendo o funcionamento da API. A âncora usada volta no corpo da resposta (`anchor`), então a leitura é auditável.
- API com **1 worker uvicorn** (não 2): o cache é em memória do processo, e cada worker extra é mais um cache independente — a mesma chave seria buscada uma vez por worker, enfraquecendo o cache justamente sob rajada. Escalar é trabalho de réplica no orquestrador.
- Instituição sem dados responde **404**, não 200 com zeros: para um roteador automatizado, "não sei" e "saudável com zero tráfego" levam a decisões opostas.

Desvios do plano:
1. **Teste `02.2` atualizado (8/11 → 10/13 serviços).** Não é regressão: esta etapa tirou `api` e `ref-sync` do profile `pendente`, que era onde estavam por ainda não terem Dockerfile. Os números antigos descreviam o esqueleto. Registrado em `99-validacao-final.md`.
2. **`/fraud/duplicates` retorna 0 linhas** — mesma limitação já declarada para a Q4 no `desafio-1/REPORT.md`: com `amount` log-normal contínuo e 500k contas, coincidência exata de valor + origem + destino em 5 min é desprezível. **A lógica foi provada à parte** sobre dado sintético (par a 2 min detectado, par a 8 h ignorado), então o 0 é propriedade do dataset, não defeito da query.
3. **Query de `/institutions/{code}/health` reescrita com subconsulta.** A forma direta (`sum(countMerge(cnt))`) é `ILLEGAL_AGGREGATION` no ClickHouse — agregação dentro de agregação. Merge na subconsulta, soma na externa; resultado conferido contra a raw (P95 55.604s vs 57.407s, avg 6.215 vs 6.215).
4. **Testes `14.3`/`14.15` reescritos após instabilidade.** A 1ª versão comparava dois acertos de cache (~0,006–0,010 ms), onde o ruído de agendamento decide o vencedor. Passaram a comparar **miss contra hit** com chave inédita por execução (`$$`). Verificado em 12 repetições isoladas + 3 suítes completas seguidas.

Observação para a próxima etapa (não é desvio desta): o teste `E2.4` (13.5) falha de forma intermitente com o banco ocioso — o `sync-worker` só registra ciclo de sucesso quando há linha nova, e o intervalo entre sucessos passa de 300s naturalmente. Sem defeito no worker; relevante para o desenho do alerta na etapa 15.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (bloco `# --- 14 ref-sync-api-e-adr ---`, 21 testes)
- [x] run_all.sh sem FAIL — 139 pass, 0 fail, 3 skip (estável em 3 execuções seguidas)
- [x] ESTADO HERDADO da próxima preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → registrado em `99-validacao-final.md`
- [x] Commit checkpoint
- [x] Mover pra concluidas/. Marcar [x] no CLAUDE.md
