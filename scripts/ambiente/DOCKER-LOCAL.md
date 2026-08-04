# Ficha do ambiente local

Ambiente real de execução. **Enquanto houver `<PREENCHER>` neste arquivo, toda etapa de trilha `carga-real` permanece `BLOQUEADA`** (etapas 05, 06, 07, 08, 12, 13 e 99).

## Campos

- Docker version: 29.6.1 (verificado)
- Compose version: v5.3.0 (verificado)
- RAM disponível para Docker: `<PREENCHER>`   ← S08 assume máquina de 32GB
- Disco livre: `<PREENCHER>`                  ← seed ~4GB + backups + WAL
- Portas livres 5432/5433/8123/9000/3000/9092/8083/9090/9002/8000/8001/8002: `<PREENCHER>`
- Seed de 10M concluído: `<PREENCHER: sim/não + data>`
- Tempo real do seed: `<PREENCHER>`
- WSL2 backend ativo: `<PREENCHER>`

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
