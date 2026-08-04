# 15 — OBSERVABILIDADE, RUNBOOK E INCIDENTE  [compose]

> **Escopo reduzido na reconciliação da esteira.** A parte de backup e recovery
> desta etapa (PDF § 5.2 A.1 e A.2) foi entregue na etapa 13.5 (commit
> `f8a0e2e`). O que resta aqui é § 5.2 A.3 (runbook), B.1/B.2 (dashboards e
> alertas) e C (incidente). Critérios de backup movidos para 13.5, não perdidos.

## ORIGEM
`../vault-estudo/03-Fluxo-Desenvolvimento/E11-Dashboards-Alertas.md` § Os 4 dashboards · § Os alertas; `../vault-estudo/03-Fluxo-Desenvolvimento/E12-Runbook-Incidente.md` § Peça 1 — O runbook de storage · § Peça 2 — O incidente SEV-1 · § A árvore de hipóteses · § A estrutura

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado ao fechar a etapa 14:
- **API de pé em `:8000`** (`desafio-2/pipeline/api/`), profile `core`+`full`, 3 endpoints de negócio + `/health` e `/metrics`. Métricas Prometheus já expostas: `api_requests_total{endpoint,outcome}`, `api_cache_hits_total`, `api_cache_misses_total`, `api_request_duration_seconds` — **prontas para os dashboards desta etapa, não precisam ser criadas**.
- **ref-sync de pé em `:8002`** (`desafio-2/pipeline/ref-sync/`), ciclo de 5 min. Métrica-chave: `refsync_dictionary_age_seconds` (frescor do Dictionary) e `refsync_last_success_timestamp`. Serve o alerta de "dado de referência velho".
- **sync-worker** segue em `:8001` desde a 13.5, com `sync_last_success_timestamp` — é a série que detecta o SEV-1 (pipeline parado). **Atenção para o alerta desta etapa**: o worker só registra ciclo de sucesso quando há linha nova; com banco ocioso o intervalo entre sucessos passa de 300s naturalmente. Um alerta de "pipeline parado" cru sobre essa série dá falso positivo em ambiente ocioso — o teste `E2.4` do `run_all.sh` já expõe esse comportamento (falhou de forma intermitente na 14 por esse motivo, sem defeito no worker).
- **`prometheus` está no profile `full`** e precisa dos 3 targets (`:8000`, `:8001`, `:8002`) para os dashboards. Conferir `init/prometheus/` ao começar.
- **Diagramas em `desafio-2/diagrams/`** (3 arquivos `.mmd`, renderização validada com `minlag/mermaid-cli`): `03-pontos-de-falha.mmd` já enumera 7 falhas com mitigação — **é a base pronta da árvore de hipóteses** do `incident-response.md`.
- **`desafio-2/ADR.md`** registra a limitação do `DELETE` e o alarme sobre `sync_last_success_timestamp` como escolha central de resiliência. O runbook desta etapa deve ser consistente com isso.
- `docker compose --profile core` **voltou a funcionar** (10 serviços; `full` = 13). O bug de `depends_on` do grafana→prometheus não reapareceu; teste `02.7` guarda a regressão.
- `run_all.sh`: blocos 01–14, **139 pass / 0 fail / 3 skip** (os 3 SKIP são `make` ausente neste Windows). `audit.sh`: 83 pass / 0 fail / 2 warn / 1 skip.
- Dado do legado **restaurado ao original** após o teste `14.4` (que faz UPDATE e desfaz): `partner_institutions` code `001` = "Instituição Parceira 1", 15 linhas.

## ESCOPO
Faz: 4 dashboards Grafana, 6 alertas com os 5 campos exigidos e integração CloudWatch/SNS descrita, `desafio-3/runbook.md` e `desafio-3/incident-response.md` com a árvore de ≥5 hipóteses.
Não faz: **não refaz backup nem recovery** — entregues na 13.5 (`desafio-3/backup/`, `restore-drill.sh`, RTO/RPO medidos). Não provisiona AWS: a parte de produção é documento escrito.

## PASSOS
1. Provisionar os 4 dashboards de E11: TimescaleDB, ClickHouse, Pipeline (métricas `sync_*` do sync-worker) e PostgreSQL Legado — este último é onde o bloat induzido na etapa 10 aparece. Provisionamento por arquivo em `init/grafana/provisioning/dashboards/`, não criado pela UI.
2. O dashboard de Pipeline consome as métricas que o sync-worker já publica (`sync_last_success_timestamp`, `sync_lag_seconds`, `sync_rows_written_total`, `sync_errors_total`, `sync_batch_duration_seconds`, `sync_watermark_timestamp`) — conferir os nomes reais em `desafio-2/pipeline/sync-worker/metrics.py` antes de escrever o painel.
3. Subir o Prometheus com `init/prometheus/prometheus.yml` (o serviço existe no compose desde a etapa 02, mas sem arquivo de configuração — é o que o faz reiniciar em loop).
4. Configurar os 6 alertas de E11 § Os alertas (o PDF § 5.2 B.2 pede no mínimo 5). Para **cada** alerta documentar os 5 campos: métrica, threshold, severidade, ação esperada e **como integraria com CloudWatch/SNS na AWS**. Vai em `desafio-3/grafana/alertas.md`.
5. Um dos alertas deve ser sobre `sync_last_success_timestamp` — é a métrica que detecta o cenário SEV-1 do PDF § 5.2 C (pipeline parado sem erro aparente).
6. Escrever `desafio-3/runbook.md` — nome literal da árvore do PDF § 6 — cobrindo os 5 itens do § 5.2 A.3: pré-requisitos e validações, passo a passo com comandos SQL, checkpoints de validação, plano de rollback e comunicação para stakeholders. Cenário: storage em 92%, sanitizar chunks de 6+ meses sem downtime.
7. Escrever `desafio-3/incident-response.md` com os 5 blocos do PDF § 5.2 C: linha de investigação (ordem, comandos, **quais logs/métricas AWS** consultaria), árvore de ≥5 hipóteses ordenadas por probabilidade — considerando que houve **manutenção no TimescaleDB E mudança de security group** —, resolução detalhada da mais provável com comandos, ações pós-incidente **preventivas** (não só detectivas), e comunicação durante e após.
8. Acrescentar o bloco `# --- 15 observabilidade-runbook-e-incidente ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] Os 4 dashboards aparecem provisionados no Grafana e carregam **dado real** (não painel vazio)
- [ ] `prometheus` sobe e fica estável, com os alvos ativos
- [ ] O dashboard de Pipeline mostra as métricas do sync-worker com os nomes reais de `metrics.py`
- [ ] Os 6 alertas existem, cada um com métrica, threshold, severidade, ação esperada e integração CloudWatch/SNS
- [ ] Ao menos 1 alerta cobre `sync_last_success_timestamp` (detecção do SEV-1)
- [ ] `runbook.md` cobre os 5 itens do PDF § 5.2 A.3, com comandos SQL reais
- [ ] `incident-response.md` cobre os 5 blocos do PDF § 5.2 C
- [ ] A árvore tem ≥5 hipóteses ordenadas por probabilidade e considera **as duas** pistas (manutenção no Timescale e security group)
- [ ] Ações pós-incidente incluem medidas **preventivas**, não só detectivas
- [ ] Dataset principal intacto: `count(*)` de `transactions` inalterado

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 15.1 | compose | `curl -s -u admin:admin localhost:3000/api/search?type=dash-db \| jq length` | `4` |
| 15.2 | compose | `curl -s localhost:9090/api/v1/targets \| jq '[.data.activeTargets[]\|select(.health=="up")]\|length'` | ≥ 1 |
| 15.3 | compose | contagem de regras de alerta provisionadas | `6` |
| 15.4 | local | `grep -ci 'cloudwatch\|sns' desafio-3/grafana/alertas.md` | ≥ 6 (1 por alerta) |
| 15.5 | local | `grep -c 'sync_last_success_timestamp' desafio-3/grafana/alertas.md` | ≥ 1 |
| 15.6 | local | `test -f desafio-3/runbook.md -a -f desafio-3/incident-response.md` | sai 0 |
| 15.7 | local | `grep -c '^### Hipótese' desafio-3/incident-response.md` | ≥ 5 |
| 15.8 | local | `grep -ci 'security group' desafio-3/incident-response.md` | ≥ 1 (2ª pista do PDF) |
| 15.9 | carga-real | `psql -tAc "SELECT count(*) FROM transactions"` | `10000000` (inalterado) |

## ROLLBACK
```bash
docker compose stop grafana prometheus
git checkout -- desafio-3/ init/grafana/ init/prometheus/
```
> Etapa documental e de provisionamento; não toca dado.

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
