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
