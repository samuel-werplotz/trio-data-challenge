# LOG DE EXECUÇÃO

Scratchpad descartável, não histórico permanente. Mínimo, sem prosa. Campo que não se aplica é omitido. Nunca repetir o que já está no commit ou no `.md` da etapa concluída.

Formato do bloco, um por etapa:

```
## NN · AAAA-MM-DD
Quebrou: <o que falhou, ou omitir>
Decidido: <o que foi decidido, ou omitir>
```

---

## 01 · 2026-08-03

## 02 · 2026-08-03
Decidido: paths de build local sem S-doc (ref-sync, api) seguem convenção do cdc-consumer (S05: `desafio-2/pipeline/<serviço>/`). Validação de `up --profile core` restrita aos 4 serviços com imagem pronta — seed/api (build) ficam para 05/14.

## 03 · 2026-08-03
Quebrou: `winget install GnuWin32.Make` falhou por erro de rede (Sourceforge). Sem `make` no PATH deste Windows.
Decidido: validar `make help`/`make -n up`/`make seed`/`make check` via container Docker auxiliar (`docker:27-cli` + socket montado + `COMPOSE_PROJECT_NAME` explícito), já que Docker está de pé. `run_all.sh` faz SKIP nos 3 testes que dependem de `make` neste ambiente específico.

## 04 · 2026-08-03
Quebrou: primeira versão de `02_seed_marker.sql` usou colunas inventadas em vez das literais de S02 — pego ao ler a ORIGEM da etapa 05, corrigido antes do commit.
Decidido: volume do timescaledb recriado 2x (schema inicial + correção do seed_control) — sem perda de dado real, nenhum seed havia rodado.

## 05 · 2026-08-04
Quebrou: `COPY BINARY` com `float`/sem `set_types` corrompia o stream binário (NUMERIC e CHAR(3)); timestamps do mês corrente geravam dado no futuro. Todos corrigidos antes do seed real rodar.
Decidido: seed real de 10M rodou em 1m57s (vs ~20min estimado em S02) — 6 workers, COPY BINARY em lotes de 50k. 12 meses do dataset terminam no mês corrente para a janela de pending/48h cair dentro do range.

## 06 · 2026-08-04
Quebrou: Q4 (self-join) estourava `/dev/shm` (64MB default) — nosso volume em 7 dias é ~5x a referência de S06.
Decidido: `shm_size: 1gb` no serviço timescaledb (docker-compose.yml). Medianas registradas: Q1 12.115ms, Q2 8.103ms, Q3 1.285ms, Q4 2.814ms (self-join mais rápido que o esperado — planejador usou Parallel Hash Join).

## audit.sh · 2026-08-04
Quebrou: `audit.sh` só buscava etapas em `scripts/roadmap/*.md` — depois que uma etapa fecha e move para `concluidas/`, o script deixa de achá-la e reporta FAIL falso (arquivo ausente, esteira com número errado de etapas BLOQUEADA, decisões/PDF não rastreados). Regressão silenciosa a cada fechamento de etapa desde a 02.
Decidido: `step_file NN` resolve o caminho da etapa em `$ROADMAP` ou `$ROADMAP/concluidas`; `has_impeditivo_ficha` checa só dentro da seção `## IMPEDITIVOS` (não em prosa livre de STATUS) para não pegar falso-positivo. A6.2 (código de aplicação "antes da hora") virou condicional a `-d trio-data-challenge` — só faz sentido antes da etapa 01. `audit.sh` volta a 0 FAIL de forma estável, não é mais preciso ignorar FAILs "conhecidos" a cada fechamento.
