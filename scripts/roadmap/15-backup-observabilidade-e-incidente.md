# 15 — BACKUP, OBSERVABILIDADE E INCIDENTE  [compose]

## ORIGEM
`../vault-estudo/06-Especificacao/S07-Legado-e-Backup.md` § Parte 2 — Backup (Configuração do pgBackRest, Habilitação do arquivamento, Agenda, ClickHouse) · § Parte 3 — O exercício de recuperação · § A saída esperada · § Parte 4 — Documentação AWS (escrita, não executada); `../vault-estudo/03-Fluxo-Desenvolvimento/E11-Dashboards-Alertas.md` § Os 4 dashboards · § Os alertas; `../vault-estudo/03-Fluxo-Desenvolvimento/E12-Runbook-Incidente.md` § Peça 1 — O runbook de storage · § Peça 2 — O incidente SEV-1 · § A árvore de hipóteses

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
<preenchido pela etapa 14 ao fechar>

## ESCOPO
Faz: backup dos **três** bancos (TimescaleDB e PostgreSQL legado via pgBackRest → MinIO com `repo1-type=s3` na 9002; ClickHouse via `clickhouse-backup`), cada um com tipo/frequência/retenção declarados e o destino AWS de produção escrito; `scripts/restore-drill.sh` simulando perda real e validando com as 3 contagens; 4 dashboards; 6 alertas com integração CloudWatch/SNS descrita; `desafio-3/runbook.md`; `desafio-3/incident-response.md` com a árvore de 6 hipóteses.
Não faz: **não provisiona AWS** — a parte 4 de S07 é documento escrito; o restore-drill roda em instância/banco separado, nunca sobre o dataset principal.

## PASSOS
1. Configurar pgBackRest com `repo1-type=s3` apontando para o MinIO na **9002** (a 9000 é do ClickHouse); habilitar o arquivamento de WAL conforme S07 § Habilitação do arquivamento. Cobrir **os dois** PostgreSQL: o TimescaleDB e o legado — o PDF § 5.2 A.1 exige estratégia para os **três** bancos, e só o principal estava previsto. Stanza própria por instância.
2. Configurar `clickhouse-backup` e registrar a agenda de S07 § Agenda.
3. Escrever, para **cada um dos 3 bancos**, os 4 itens que o PDF § 5.2 A.1 cobra: tipo de backup (físico/lógico, full/incremental), frequência e retenção, o script que executa, e **onde armazenaria em produção na AWS** (bucket S3, lifecycle policy, cross-region). Vai em `desafio-3/backup/README.md` como tabela.
4. Escrever `scripts/restore-drill.sh` conforme o protocolo do PDF § 5.2 A.2: **simular a perda** (`DELETE` de transações de um período), depois restaurar do backup, registrando **timestamp e contagem nos 3 momentos** — antes da perda, depois da perda, após o recovery. Comparar `sum(amount)` origem vs restaurado e **medir** RTO e RPO. A saída deve bater com S07 § A saída esperada.
5. Provisionar os 4 dashboards de E11: TimescaleDB, ClickHouse, Pipeline e PostgreSQL Legado — o do legado é onde o bloat induzido na etapa 10 aparece.
6. Configurar os 6 alertas de E11 § Os alertas (o PDF § 5.2 B.2 pede no mínimo 5). Para **cada** alerta, documentar os 5 campos exigidos: métrica, threshold, severidade, ação esperada e **como integraria com CloudWatch/SNS na AWS**.
7. Escrever `desafio-3/runbook.md` — nome literal da árvore do PDF § 6 — com a estrutura de E12 § A estrutura, cobrindo os 5 itens que o PDF § 5.2 A.3 exige: pré-requisitos e validações, passo a passo com comandos SQL, checkpoints de validação, plano de rollback e comunicação para stakeholders.
8. Escrever `desafio-3/incident-response.md` com os 5 blocos do PDF § 5.2 C: linha de investigação (ordem, comandos/queries, **quais logs/métricas AWS** consultaria), árvore de ≥5 hipóteses ordenadas por probabilidade — considerando que houve **manutenção no TimescaleDB E mudança de security group** —, resolução detalhada da mais provável com comandos, ações pós-incidente **preventivas** (não só detectivas), e comunicação durante e após.
9. Acrescentar o bloco `# --- 15 backup-observabilidade-e-incidente ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] `pgbackrest check` passa nas **duas** stanzas (TimescaleDB e legado)
- [ ] Backup full completa e fica visível no MinIO
- [ ] `clickhouse-backup list` mostra ao menos 1 backup
- [ ] Os **3 bancos** têm tipo, frequência, retenção e destino AWS de produção documentados
- [ ] `restore-drill.sh` simula a perda e imprime as **3 contagens** (antes, depois da perda, após recovery) com timestamp
- [ ] `sum(amount)` do restaurado bate exatamente com o da origem
- [ ] RTO e RPO **medidos**, com número, não estimados
- [ ] Os 4 dashboards aparecem provisionados no Grafana e carregam dado real
- [ ] Os 6 alertas existem, cada um com métrica, threshold, severidade, ação esperada e integração CloudWatch/SNS
- [ ] `runbook.md` e `incident-response.md` existem; a árvore tem ≥5 hipóteses ordenadas por probabilidade
- [ ] Runbook cobre os 5 itens do PDF; incident-response cobre os 5 blocos do PDF, incluindo métricas/logs AWS
- [ ] Dataset principal intacto: `count(*)` de `transactions` inalterado

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 15.1 | compose | `docker compose exec -T timescaledb pgbackrest --stanza=trio check` | sai 0 |
| 15.2 | compose | `docker compose exec -T postgres-legado pgbackrest --stanza=legado check` | sai 0 (3º banco) |
| 15.3 | compose | `docker compose exec -T clickhouse clickhouse-backup list \| wc -l` | ≥ 1 |
| 15.4 | compose | `bash scripts/restore-drill.sh` | sai 0; 3 contagens impressas; checksum idêntico; RTO/RPO impressos |
| 15.5 | compose | `curl -s -u admin:admin localhost:3000/api/search?type=dash-db \| jq length` | `4` |
| 15.6 | compose | contagem de regras de alerta provisionadas | `6` |
| 15.7 | local | `grep -ci 'cloudwatch\|sns' desafio-3/grafana/alertas.md` | ≥ 6 (1 por alerta) |
| 15.8 | local | `test -f desafio-3/runbook.md -a -f desafio-3/incident-response.md -a -f desafio-3/backup/README.md` | sai 0 |
| 15.9 | local | `grep -c '^### Hipótese' desafio-3/incident-response.md` | `6` |
| 15.10 | local | `grep -ci 's3\|lifecycle' desafio-3/backup/README.md` | ≥ 3 (destino AWS dos 3 bancos) |

## ROLLBACK
```bash
docker compose exec -T timescaledb pgbackrest --stanza=trio stop
docker compose exec -T clickhouse clickhouse-backup delete local <nome-do-backup>
git checkout -- desafio-3/ init/grafana/
```
> O restore-drill roda em alvo separado; não há rollback sobre o dataset principal.

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
