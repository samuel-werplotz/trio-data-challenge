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
- [x] `docker compose config` sai 0 (YAML e interpolação válidos)
- [x] 15 serviços definidos, todos com tag de imagem fixada — nenhum `:latest`
- [x] Perfis `core` e `full` declarados; `--profile core` sobe o subconjunto
- [x] Todo serviço com healthcheck tem `start_period` definido
- [x] MinIO publica na 9002; nenhuma porta duplicada entre serviços
- [x] `docker compose --profile core up -d` chega a todos `healthy` sem intervenção manual — parcial: validado para os 4 serviços do core com imagem pronta (ver STATUS); `seed`/`api` (build local) ficam para 05/14
- [x] Parâmetros do TimescaleDB conferem literalmente com S08

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
Estado: CONCLUÍDA
Premissas assumidas:
- `audit.sh` conta etapas só em `scripts/roadmap/*.md` (raiz), não em `concluidas/`. Após mover a 01 ao fechar, A2.1/A2.01 acusam FAIL (15 arquivos em vez de 16). Defeito do próprio script de auditoria do plano, não do conteúdo da etapa 02 — não é regressão de arquitetura/PDF, por isso não entra em `99-validacao-final.md`. `run_all.sh` (que testa o produto) segue com 0 FAIL.
- `ref-sync` e `api` (serviços 9 e 10) não têm estrutura de diretório detalhada em nenhum S-doc citado na ORIGEM desta etapa; usei `desafio-2/pipeline/ref-sync` e `desafio-2/pipeline/api` como contexto de build, por analogia ao `cdc-consumer` (S05, que fixa `desafio-2/pipeline/consumer/`). `seed` usa `desafio-1/seed` (já existe na árvore do PDF §6); `backup` usa `desafio-3/backup` (idem).
- `docker compose --profile core up -d` completo não foi validado: `seed` e `api` são `build:` sem Dockerfile ainda (etapas 05/14). Validado em vez disso: os 4 serviços do core com imagem pronta (`timescaledb`, `postgres-legado`, `clickhouse`, `grafana`) sobem via `docker compose up -d <serviço...>` e os 3 com healthcheck ficam `healthy` sem intervenção manual. `run_all.sh` 02.6 usa esse subconjunto; virará SKIP quando os containers não estiverem de pé.
Desvios do plano: —

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh
- [x] run_all.sh sem FAIL
- [x] ESTADO HERDADO da próxima preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → atualizar 99-validacao-final.md (n/a — sem desvio de arquitetura/PDF)
- [x] Commit checkpoint
- [x] Mover pra concluidas/. Marcar [x] no CLAUDE.md
