# 01 — BASELINE E ESTRUTURA  [local]

## ORIGEM
Sem S-doc — levantamento do estado atual + PDF § 6 "Estrutura de Entrega" (árvore sugerida do repositório)

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado no início desta esteira:
- Raiz alvo `Trio/trio-data-challenge/` contém **apenas** a pasta aninhada `trio-data-challenge/`, com: `docker-compose.yml`, `.env.example`, `README.md`, `init/`.
- `init/` do starter traz 4 arquivos: `init/timescaledb/00_init.sql`, `init/postgres-legado/00_init.sql`, `init/clickhouse/00_init.sql`, `init/grafana/provisioning/datasources/datasources.yml`.
- **Não há `git init`** nesta pasta. O git root atual é `C:/Users/samue/OneDrive/Documentos/GitHub`, sem nenhum commit.
- `scripts/` já existe com `roadmap/`, `ambiente/`, `tests/` (criados na geração do plano). `CLAUDE.md` já está na raiz.
- Docker 29.6.1 / Compose v5.3.0 disponíveis. Windows 11, PowerShell primário, Git Bash disponível.
- Documentação de arquitetura em `../vault-estudo/` — **fora** do repo, não copiar pra dentro.

## ESCOPO
Faz: achatar o aninhamento duplicado, inicializar o git nesta pasta com a branch de trabalho, criar `.gitignore` e a árvore de diretórios do PDF § 6, e inventariar o que o starter já traz.
Não faz: não escreve conteúdo de aplicação (nenhum SQL, Python, YAML ou Dockerfile); não altera o `docker-compose.yml` do starter — isso é a etapa 02.

## PASSOS
1. Mover o conteúdo de `trio-data-challenge/trio-data-challenge/` um nível acima (incluindo ocultos: `.env.example`) e remover a pasta interna, agora vazia.
2. `git init` na raiz alvo; criar e entrar na branch `wip/trio-challenge`.
3. Escrever `.gitignore` cobrindo: `.env`, `__pycache__/`, `*.pyc`, `.venv/`, dumps de backup, `queries/explains/*.raw`.
4. Criar a árvore do PDF § 6 com `.gitkeep` nas pastas vazias: `desafio-1/{schemas,seed,queries}`, `desafio-2/{pipeline,diagrams}`, `desafio-3/{backup,grafana}`, `docs/`.
5. Inventariar o starter em `docs/INVENTARIO-STARTER.md`: para cada um dos 4 arquivos de `init/`, o que já define e o que a etapa correspondente vai substituir ou estender.
6. Acrescentar o bloco `# --- 01 baseline-e-estrutura ---` em `scripts/tests/run_all.sh`.
7. Fechar pelo checklist.

## CRITÉRIOS DE ACEITE
- [x] `trio-data-challenge/trio-data-challenge/` não existe mais
- [x] `docker-compose.yml`, `.env.example`, `README.md` e `init/` estão na raiz alvo
- [x] `git rev-parse --show-toplevel` aponta para a raiz alvo (não para `GitHub/`)
- [x] `git branch --show-current` retorna `wip/trio-challenge`
- [x] `.gitignore` existe e `git status` não lista `.env`
- [x] As 8 pastas da árvore do PDF § 6 existem e estão versionadas via `.gitkeep`
- [x] `docs/INVENTARIO-STARTER.md` cobre os 4 arquivos do `init/`
- [x] `../vault-estudo/` e o PDF **não** foram copiados pra dentro do repo

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 01.1 | local | `test ! -d trio-data-challenge` | sai 0 (aninhamento achatado) |
| 01.2 | local | `test -f docker-compose.yml -a -f .env.example -a -d init` | sai 0 |
| 01.3 | local | `git rev-parse --show-toplevel` | termina em `/trio-data-challenge` |
| 01.4 | local | `git branch --show-current` | `wip/trio-challenge` |
| 01.5 | local | `test -d desafio-1/schemas -a -d desafio-2/pipeline -a -d desafio-3/backup -a -d docs` | sai 0 |
| 01.6 | local | `grep -q '^\.env$' .gitignore` | sai 0 |
| 01.7 | local | `test ! -e vault-estudo -a -z "$(ls *.pdf 2>/dev/null)"` | sai 0 (nada de estudo dentro do repo) |

## ROLLBACK
```bash
rm -rf .git desafio-1 desafio-2 desafio-3 docs .gitignore
mkdir -p trio-data-challenge
mv docker-compose.yml .env.example README.md init trio-data-challenge/
```

## STATUS
Estado: CONCLUÍDA
Premissas assumidas: —
Desvios do plano: —

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh
- [x] run_all.sh sem FAIL
- [x] ESTADO HERDADO da próxima preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → atualizar 99-validacao-final.md (n/a — sem desvio)
- [x] Commit checkpoint
- [x] Mover pra concluidas/. Marcar [x] no CLAUDE.md
