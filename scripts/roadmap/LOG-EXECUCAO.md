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
