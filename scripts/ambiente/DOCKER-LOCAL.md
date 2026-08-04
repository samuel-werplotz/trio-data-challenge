# Ficha do ambiente local

Ambiente real de execução. **Enquanto houver `<PREENCHER>` neste arquivo, toda etapa de trilha `carga-real` permanece `BLOQUEADA`** (etapas 05, 06, 07, 08, 12, 13 e 99).

## Campos

- Docker version: 29.6.1 (verificado)
- Compose version: v5.3.0 (verificado)
- RAM disponível para Docker: **8.3 GB** (`docker info --format '{{.MemTotal}}'` = 8329084928 bytes) ← **abaixo dos 32GB que S08 assume**. Ver nota de risco abaixo.
- Disco livre: **282 GB** livres no drive C: (925 GB total, 644 GB usados) — folgado para seed ~4GB + backups + WAL
- Portas livres 5432/5433/8123/9000/3000/9092/8083/9090/9002/8000/8001/8002: **todas livres** (verificado com ambiente derrubado via `docker compose --profile full down`)
- Seed de 10M concluído: não (etapa 05 ainda BLOQUEADA — aguardando esta ficha)
- Tempo real do seed: —
- WSL2 backend ativo: **sim** (`Kernel Version: 6.6.87.2-microsoft-standard-WSL2`, `Operating System: Docker Desktop`)

## Como preencher

| Campo | Comando |
|---|---|
| RAM / WSL2 | `docker info --format '{{.MemTotal}} {{.OperatingSystem}}'` |
| Disco livre | `docker system df` + espaço livre do drive do Docker |
| Portas | `netstat -ano \| findstr "5432 5433 8123 9000 3000 9092 8083 9090 9002 8000 8001 8002"` (vazio = livre) |
| Seed / tempo | preenchido pela etapa 05 ao concluir |

## Notas

- MinIO fica em **9002**, não em 9000: a 9000 é a porta nativa do ClickHouse (decisão de S08).
- Seed de 10M custa ~20 min (premissa registrada). Por isso as etapas que dependem da carga completa estão separadas das que só precisam do schema — iterar numa não força repetir o seed.
- **Risco conhecido — RAM abaixo da premissa de S08**: máquina real tem 8.3 GB alocados ao Docker, não os 32 GB que S08 assume. Perfil `core` (4 serviços de imagem pronta) já validado sem problema. Perfil `full` declara ~20 GB de teto — pode não caber inteiro de uma vez. Decisão: seguir sem redesenhar memória agora; se algum container morrer por OOM numa etapa de carga real (05, 12, 13, 15), tratar ali com o sintoma em mãos — provável mitigação: não subir o perfil `full` inteiro simultaneamente, subir por subconjunto conforme a etapa precisar.
