# 03 — MAKEFILE E HEALTHCHECK  [compose]

## ORIGEM
`../vault-estudo/06-Especificacao/S08-Compose-e-Makefile.md` § Makefile (ciclo de vida, dados, pipeline, demonstrações, operação, verificação) · § Por que o Makefile importa na apresentação · § O script `health-check.sh`

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado ao fechar a etapa 02:
- `docker-compose.yml` na raiz com os 15 serviços de S08, perfis `core`/`full` em todo serviço (sem profile default — `docker compose config` sozinho resolve `services: {}`; usar `--profile full` ou `--profile core`).
- Serviços com `image:` (10): timescaledb, postgres-legado, clickhouse, grafana, redpanda, debezium, prometheus, pg-exporter-ts, pg-exporter-legado, minio. Serviços com `build:` (5, sem Dockerfile ainda): seed (`./desafio-1/seed`), cdc-consumer (`./desafio-2/pipeline/consumer`), ref-sync (`./desafio-2/pipeline/ref-sync`), api (`./desafio-2/pipeline/api`), backup (`./desafio-3/backup`).
- Healthcheck com `start_period` em 6 serviços: timescaledb, postgres-legado, clickhouse, redpanda, debezium, minio. `grafana` depende de `timescaledb`+`clickhouse`+`postgres-legado` (`service_healthy`) e `prometheus` (`service_started`), sem healthcheck próprio.
- Cadeia de dependências de S08 aplicada (seed, debezium, cdc-consumer, grafana).
- MinIO publica 9002 externamente (9000 é nativo do ClickHouse dentro da rede).
- Validado com Docker de pé: os 4 serviços do core com imagem pronta (timescaledb, postgres-legado, clickhouse, grafana) sobem via `docker compose up -d <serviço...>` e os 3 com healthcheck próprio ficam `healthy` sem intervenção manual. `--profile core up -d` completo (com seed/api) só será validável após as etapas 05/14 criarem os Dockerfiles.
- `prometheus` reinicia em loop se subir sozinho: falta `./init/prometheus` (config ainda não existe, fora do escopo da 02 e da 03).
- `.env` criado localmente a partir de `.env.example` (não versionado — coberto pelo `.gitignore`).
- `scripts/tests/run_all.sh` com blocos `01` (7 checks) e `02` (6 checks, 02.6 é SKIP sem containers de pé).

## ESCOPO
Faz: `Makefile` com todos os alvos de S08 e um `help` auto-documentado, mais `scripts/wait-healthy.sh` e `scripts/health-check.sh`.
Não faz: não implementa o que os alvos chamam (`seed`, `pipeline`, `backfill` etc. apontam para scripts das etapas futuras); alvo cujo script ainda não existe deve falhar com mensagem clara, não silenciosamente.

## PASSOS
1. Extrair de S08 § Makefile a lista completa de alvos, agrupados nas 6 seções do doc: ciclo de vida, dados, pipeline, demonstrações, operação, verificação.
2. Escrever o `Makefile` com `help` como alvo padrão, auto-documentado a partir dos comentários `##` de cada alvo.
3. Escrever `scripts/wait-healthy.sh`: espera os serviços ficarem `healthy` com timeout e saída diagnóstica quando estoura.
4. Escrever `scripts/health-check.sh` conforme S08 § O script `health-check.sh` — uma linha por verificação, exit code agregado.
5. Marcar como executáveis (`chmod +x`) e conferir shebang `#!/usr/bin/env bash`.
6. Rodar `make help` e `make check` com o perfil `core` de pé.
7. Acrescentar o bloco `# --- 03 makefile-e-healthcheck ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] `make help` lista **todos** os alvos, cada um com uma linha de descrição
- [ ] `help` é o alvo padrão (`make` sem argumento não destrói nada)
- [ ] Todos os alvos de S08 § Makefile existem, nenhum a mais sem justificativa em `## STATUS`
- [ ] `scripts/health-check.sh` e `scripts/wait-healthy.sh` são executáveis
- [ ] `make check` roda e retorna exit code coerente (0 com tudo de pé)
- [ ] Alvo cujo script ainda não existe falha com mensagem explícita nomeando a etapa que o cria

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 03.1 | local | `make help` | sai 0, lista os alvos |
| 03.2 | local | `make -n up` | sai 0 (alvo existe e expande) |
| 03.3 | local | `test -x scripts/health-check.sh -a -x scripts/wait-healthy.sh` | sai 0 |
| 03.4 | local | `bash -n scripts/health-check.sh && bash -n scripts/wait-healthy.sh` | sai 0 (sintaxe) |
| 03.5 | compose | `make check` | sai 0 com perfil `core` healthy |

## ROLLBACK
```bash
rm -f Makefile scripts/health-check.sh scripts/wait-healthy.sh
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
