# 02 — COMPOSE EVOLUÍDO  [compose]

## ORIGEM
`../vault-estudo/06-Especificacao/S08-Compose-e-Makefile.md` § Os 15 serviços · § Versões fixadas, não `latest` · § Ajustes no TimescaleDB · § Healthchecks · § Cadeia de dependências

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado ao fechar a etapa 01:
- Raiz achatada: `docker-compose.yml`, `.env.example`, `README.md`, `init/` na raiz do repo (não mais aninhados).
- `init/` com os 4 arquivos-placeholder do starter, inventariados em `docs/INVENTARIO-STARTER.md`.
- `docker-compose.yml` do starter tem 4 serviços (timescaledb, postgres-legado, clickhouse, grafana), sem perfis, sem MinIO/Kafka/Debezium. `wal_level=logical` já habilitado no TimescaleDB.
- Git inicializado nesta pasta (`git rev-parse --show-toplevel` termina em `/trio-data-challenge`), branch `wip/trio-challenge` ativa, primeiro commit feito (`checkpoint: 01 — baseline-e-estrutura`).
- `.gitignore` cobre `.env`, `__pycache__/`, `*.pyc`, `.venv/`, dumps de backup, `queries/explains/*.raw`.
- Árvore do PDF § 6 criada com `.gitkeep`: `desafio-1/{schemas,seed,queries}`, `desafio-2/{pipeline,diagrams}`, `desafio-3/{backup,grafana}`, `docs/`.
- `scripts/tests/run_all.sh` tem o bloco `# --- 01 baseline-e-estrutura ---` (7 checks, todos PASS).
- Ficha `scripts/ambiente/DOCKER-LOCAL.md` ainda com `<PREENCHER>` — etapas de trilha `carga-real` continuam BLOQUEADA; esta etapa (02) é trilha `compose`, liberada.

## ESCOPO
Faz: substituir o `docker-compose.yml` do starter pela versão de 15 serviços de S08 — versões fixadas, perfis `core`/`full`, healthchecks com `start_period`, cadeia de `depends_on: condition: service_healthy`, ajustes de parâmetro do TimescaleDB e MinIO exposto na 9002.
Não faz: não escreve Makefile nem `health-check.sh` (etapa 03); não cria schema nenhum (etapa 04); não sobe o perfil `full`, só o `core`.

## PASSOS
1. Ler S08 § Os 15 serviços e listar serviço → imagem → tag fixada. Nenhum `latest`.
2. Escrever `docker-compose.yml`: os 15 serviços, com `profiles: [core]` / `[full]` conforme S08.
3. Aplicar os ajustes de parâmetro do TimescaleDB de S08 § Ajustes no TimescaleDB (`command:` / variáveis), mantendo os valores literais do doc.
4. Aplicar os healthchecks de S08 § Healthchecks — `test`, `interval`, `retries` e `start_period` conforme a tabela do doc.
5. Ligar a cadeia de dependências de S08 § Cadeia de dependências via `depends_on` com `condition: service_healthy`.
6. Expor MinIO na **9002** (a 9000 é a porta nativa do ClickHouse) e conferir se nenhuma outra porta colide.
7. Validar: `docker compose config` e subir `--profile core`, aguardando todos ficarem `healthy`.
8. Acrescentar o bloco `# --- 02 compose-evoluido ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] `docker compose config` sai 0 (YAML e interpolação válidos)
- [ ] 15 serviços definidos, todos com tag de imagem fixada — nenhum `:latest`
- [ ] Perfis `core` e `full` declarados; `--profile core` sobe o subconjunto
- [ ] Todo serviço com healthcheck tem `start_period` definido
- [ ] MinIO publica na 9002; nenhuma porta duplicada entre serviços
- [ ] `docker compose --profile core up -d` chega a todos `healthy` sem intervenção manual
- [ ] Parâmetros do TimescaleDB conferem literalmente com S08

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 02.1 | local | `docker compose config -q` | sai 0 |
| 02.2 | local | `docker compose config \| grep -c 'image:'` | 15 |
| 02.3 | local | `! docker compose config \| grep -q ':latest'` | sai 0 |
| 02.4 | local | `docker compose config \| grep -q '9002'` | sai 0 (MinIO fora da 9000) |
| 02.5 | local | `docker compose config --profiles \| sort -u` | contém `core` e `full` |
| 02.6 | compose | `docker compose --profile core ps --format '{{.Health}}' \| sort -u` | só `healthy` |

## ROLLBACK
```bash
git checkout -- docker-compose.yml
docker compose --profile core down
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
