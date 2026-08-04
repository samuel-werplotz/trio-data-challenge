# 14 — REF-SYNC, API E ADR  [compose]

## ORIGEM
`../vault-estudo/03-Fluxo-Desenvolvimento/E09-RefSync-ADR.md` § Parte B — O pipeline de referência · § Por que batch e não CDC · § A pergunta sobre Aurora · § Parte C — Diagrama e ADR; `../vault-estudo/02-Infraestrutura/Container-Ref-Sync.md`; `../vault-estudo/02-Infraestrutura/Container-API.md`; `../vault-estudo/06-Especificacao/S05-Pipeline-CDC.md` (contrato do consumidor, reaproveitado no ref-sync)

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
<preenchido pela etapa 13 ao fechar>

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
- [ ] `ref_sync.py` roda em ciclo de 5 min e uma mudança no legado aparece no Dictionary no ciclo seguinte
- [ ] Os 3 endpoints respondem 200 com corpo válido
- [ ] Toda resposta traz `query_ms`
- [ ] Cache de 10s comprovado: 2ª chamada idêntica tem `query_ms` menor
- [ ] Timeout configurado e testado
- [ ] Diagramas Mermaid renderizam sem erro de sintaxe
- [ ] Diagrama de arquitetura mostra serviços AWS (VPC, subnets, S3, CloudWatch), **SLAs** de latência/freshness e **pontos de falha com mitigação** — não só as caixas
- [ ] Diagrama inclui Hex e as aplicações consumidoras, além de Grafana
- [ ] `ADR.md` responde as 4 perguntas literais do PDF § 4.2 C.2 e registra a limitação do `DELETE` no plano B
- [ ] Comportamento do ref-sync sob migração para Aurora respondido por escrito (PDF § 4.2 B.2)

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
