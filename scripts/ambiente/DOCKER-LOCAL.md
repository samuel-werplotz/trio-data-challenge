# Ficha do ambiente local

Ambiente real de execução. **Enquanto houver `<PREENCHER>` neste arquivo, toda etapa de trilha `carga-real` permanece `BLOQUEADA`** (etapas 05, 06, 07, 08, 12, 13 e 99).

## Campos

- Docker version: 29.6.1 (verificado)
- Compose version: v5.3.0 (verificado)
- RAM disponível para Docker: **8.3 GB** (`docker info --format '{{.MemTotal}}'` = 8329084928 bytes) ← **abaixo dos 32 GB do dimensionamento original**. Ver nota de risco abaixo.
- Disco livre: **282 GB** livres no drive C: (925 GB total, 644 GB usados) — folgado para seed ~4GB + backups + WAL
- Portas livres 5432/5433/8123/9000/3000/9092/8083/9090/9002/8000/8001/8002: **todas livres** (verificado com ambiente derrubado via `docker compose --profile full down`)
- Seed de 10M concluído: **sim** — 2026-08-04
- Tempo real do seed: **168 s** (10.000.000 linhas, 6 workers paralelos, `COPY BINARY` em lotes de 50k). A estimativa inicial era de ~20 min e assumia hardware mais modesto — 8,3 GB de RAM local performou bem acima do esperado.
- WSL2 backend ativo: **sim** (`Kernel Version: 6.6.87.2-microsoft-standard-WSL2`, `Operating System: Docker Desktop`)

## Como preencher

| Campo | Comando |
|---|---|
| RAM / WSL2 | `docker info --format '{{.MemTotal}} {{.OperatingSystem}}'` |
| Disco livre | `docker system df` + espaço livre do drive do Docker |
| Portas | `netstat -ano \| findstr "5432 5433 8123 9000 3000 9092 8083 9090 9002 8000 8001 8002"` (vazio = livre) |
| Seed / tempo | preenchido pela etapa 05 ao concluir |

## Notas

- MinIO fica em **9002**, não em 9000: a 9000 é a porta nativa do ClickHouse.
- Seed de 10M custa **168 s (~2,8 min)** — medido na execução do zero da etapa 99, com cronômetro. A premissa original registrada aqui era "~20 min", estimativa conservadora feita antes de existir gerador: errou por **7×** para mais. A separação entre etapas que precisam da carga completa e as que só precisam do schema continua valendo, mas o custo de repetir o seed é muito menor do que se supunha.
- **Sequência completa do zero: ≈ 7 min** (`gen-certs` + rebuild ~60 s · `up` 20 s · seed 168 s · CAggs e compressão 82 s · backfill 58 s · backup 53 s). Reproduzível pelos 5 comandos do README — os dois scripts exigem um shell com `bash` (Git Bash no Windows).
- **Risco conhecido — RAM abaixo da premissa inicial**: a máquina real tem 8,3 GB alocados ao Docker, não os 32 GB do dimensionamento original. Perfil `core` (4 serviços de imagem pronta) já validado sem problema. Perfil `full` declara ~20 GB de teto — pode não caber inteiro de uma vez. Decisão: seguir sem redesenhar memória agora; se algum container morrer por OOM numa etapa de carga real (05, 12, 13, 15), tratar ali com o sintoma em mãos — provável mitigação: não subir o perfil `full` inteiro simultaneamente, subir por subconjunto conforme a etapa precisar.
