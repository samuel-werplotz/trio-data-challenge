# Estratégia de Backup e Recovery — os 3 bancos

Responde ao PDF § 5.2 A.1: para cada banco, **tipo de backup**, **frequência e retenção**, **script funcional** e **onde armazenaria em produção na AWS**.

Tudo aqui foi executado neste ambiente. Os números são medidos.

---

## Visão geral

| Banco | Ferramenta | Tipo | Destino local | PITR |
|---|---|---|---|---|
| TimescaleDB | pgBackRest 2.57 | Físico, full + incremental + WAL | MinIO (S3) | **Sim** |
| PostgreSQL legado | pgBackRest 2.59 | Físico, full + incremental + WAL | MinIO (S3) | **Sim** |
| ClickHouse | `BACKUP` nativo | Físico, full | Disco `backups` | Não |

O MinIO fala o protocolo S3 e serve HTTPS. É **o mesmo caminho de código** que rodaria contra o S3 real: migrar para produção é trocar endpoint, região e credencial — nenhuma linha de lógica muda.

---

## 1. TimescaleDB — o banco transacional principal

**Tipo: físico (`pgBackRest`), full + incremental, com arquivamento contínuo de WAL.**

Físico e não lógico porque `pg_dump` em 10M de linhas leva minutos e **não dá PITR** — recupera só o instante do dump. Com WAL arquivado, o recovery vai a qualquer ponto no tempo, que é o que um banco de pagamentos exige: o alvo não é "ontem à noite", é "13:47, um minuto antes do DELETE errado".

| Item | Valor | Medido |
|---|---|---|
| Full | 3,1 GB → **1,1 GB** no repositório (zstd-3) | **29,6s** |
| Incremental | **424 KB** | **1s** |
| WAL | contínuo, `archive_timeout=60` | — |
| Retenção | `repo1-retention-full=2` | — |

**Frequência proposta:** full semanal (domingo 03:00), incremental a cada 6h, WAL contínuo.
Full diário em 3,1 GB seria desperdício quando o incremental custa 424 KB e 1 segundo; a diferença é o WAL, que já cobre o intervalo.

**Retenção:** 2 fulls. O terceiro expira o mais antigo junto com o WAL que só ele precisava — o pgBackRest faz isso sozinho no `expire`.

**Onde roda:** `pgbackrest` está **dentro** da imagem do banco (`desafio-3/backup/timescaledb/Dockerfile`), não num container separado. Ele lê o `PGDATA` direto e é chamado pelo `archive_command` a cada segmento. Instalar em runtime funcionaria até o primeiro `docker compose down`.

> **O que já custou caro aqui:** entre as etapas 04 e E0, o compose tinha `archive_mode=on` apontando para um `pgbackrest` que não existia na imagem. Cada segmento falhava com `exit 127`, o Postgres **não recicla WAL não-arquivado**, e o `pg_wal` chegou a **17,7 GB** — 20,8 GB de volume para 3,1 GB de dado real. `archived_count` era 0 desde sempre.
>
> **Arquivamento quebrado é pior que arquivamento desligado:** dá a ilusão de ter PITR *e* enche o disco. Por isso ficou `off` do E0 ao E4, e só voltou quando o binário e o repositório existiam de verdade.

---

## 2. PostgreSQL legado

**Tipo: físico (`pgBackRest`), full + incremental, com WAL.** Mesma estratégia do principal.

| Item | Valor | Medido |
|---|---|---|
| Full | 108,2 MB | **3,9s** |
| Incremental | **8,3 KB** | **2s** |
| Retenção | 2 fulls | — |

**Frequência proposta:** full diário (03:30), incremental a cada 12h, WAL contínuo.
Pode ser mais folgada que a do principal: é dado de referência, muda pouco. Mas **tem** que existir — o PDF cobra os três bancos, e o legado alimenta o `dict_institutions` de que as queries do ClickHouse dependem.

**Nota de migração:** ao mover para Aurora, este backup **sai de cena** — Aurora tem backup contínuo gerenciado com PITR de até 35 dias. O pgBackRest aqui é justamente o custo operacional que a migração elimina, e isso é argumento para a análise em `desafio-1/migration-analysis.md`.

---

## 3. ClickHouse

**Tipo: físico, full, via comando `BACKUP` nativo.**

| Item | Valor | Medido |
|---|---|---|
| Full do banco (10M linhas) | **518 MB** | **12,8s** |
| Retenção | 3 mais recentes (`backup-all.sh`) | — |

**Por que o nativo e não `clickhouse-backup`:** a ferramenta externa **não existe na imagem** (verificado no E1 § P4). O motor nativo existe desde a 22.x e só precisava do disco de destino declarado — `backups.allowed_disk`, em `init/clickhouse-config/backup.xml`. Instalar binário de terceiro para um recurso que o servidor já tem seria dívida sem contrapartida.

**Por que não há PITR aqui, e por que tudo bem:** o ClickHouse é o **destino** de um pipeline, não a fonte da verdade. Perder o ClickHouse não perde dado — perde tempo. O `scripts/backfill-clickhouse.sh` reconstrói os 10M direto do TimescaleDB em ~56s, e o `sync-worker` reassume o incremental sozinho. **O backup do ClickHouse é otimização de RTO, não seguro contra perda.**

**Retenção:** o ClickHouse não expira backup sozinho, ao contrário do pgBackRest. `backup-all.sh` mantém os 3 mais recentes.

---

## Scripts

```bash
bash desafio-3/backup/backup-all.sh full     # full nos 3 bancos
bash desafio-3/backup/backup-all.sh incr     # incremental (ClickHouse é sempre full)
bash desafio-3/backup/restore-drill.sh       # exercício de recuperação com PITR
```

### `restore-drill.sh` — o exercício do PDF § 5.2 A.2

Simula perda, restaura e valida com as três contagens. **Restaura para uma instância paralela na porta 5499**, nunca sobre o banco principal — restaurar por cima do dataset de produção para provar que o backup funciona é o tipo de teste que vira o próprio incidente.

Saída real da última execução:

```
CONTAGEM ANTES DA PERDA:           5 linhas | R$ 500.15
CONTAGEM DEPOIS DA PERDA:          0 linhas
CONTAGEM APÓS O RECOVERY:          5 linhas | R$ 500.15
TOTAL NA INSTÂNCIA RESTAURADA:     10000005 linhas

RTO MEDIDO (restore + subir):      22s
RPO (archive_timeout):             60s (pior caso)
```

**O que este drill prova além de "o backup existe":** as 5 linhas foram criadas **depois** do último backup full. Um full sozinho jamais as recuperaria. Elas voltaram pelo **replay do WAL arquivado** até um instante escolhido — depois dos INSERTs, antes do DELETE. É a diferença entre ter backup e ter RPO.

**RTO de 22s** é o tempo de restaurar 3,1 GB e a instância aceitar conexão. **RPO de 60s** é o pior caso: com `archive_timeout=60`, no máximo o último minuto de WAL não teria sido arquivado.

> **Duas armadilhas que este drill encontrou** — ambas viram pergunta de entrevista:
> 1. A instância restaurada **recusa concluir o recovery** se `max_connections`, `max_wal_senders` ou `max_replication_slots` forem menores que os do primário (`recovery aborted because of insufficient parameter settings`). Esses parâmetros dimensionam memória compartilhada que o replay reconstrói — a réplica não pode ser menor que a origem.
> 2. A instância restaurada precisa de `archive_mode=off`. Sem isso ela escreve WAL no **repositório real**, corrompendo o histórico do banco de produção com a linha de tempo de um clone efêmero.

---

## Produção na AWS

O que muda ao sair do docker-compose. Nada disso foi provisionado — é desenho, conforme o escopo do desafio.

### Onde o dado fica

| Banco | Destino | Classe / lifecycle |
|---|---|---|
| TimescaleDB | `s3://trio-backups-prod/timescaledb/` | Standard 0–30d → **Standard-IA** 30–90d → **Glacier IR** 90d–1a → expira em 7 anos |
| PG legado / Aurora | `s3://trio-backups-prod/postgres-legado/` | idem |
| ClickHouse | `s3://trio-backups-prod/clickhouse/` | Standard 0–7d → Standard-IA → expira em 90d |

Retenção de 7 anos nos transacionais acompanha a exigência de guarda de registros financeiros; o ClickHouse é reconstruível, então 90 dias bastam.

**Trocar o MinIO pelo S3 real é editar 3 linhas do `pgbackrest.conf`:**

```ini
repo1-s3-endpoint=s3.sa-east-1.amazonaws.com
repo1-s3-region=sa-east-1
repo1-s3-key-type=auto     # IAM role da instância — sem credencial em arquivo
```

`repo1-s3-key-type=auto` é o ponto importante: em produção a credencial some do disco e vira **IAM role** (EC2 instance profile ou IRSA no EKS), com política restrita a `s3:PutObject`/`GetObject`/`ListBucket` **só no prefixo daquela stanza**.

### Resiliência do próprio backup

- **Cross-region replication** do bucket para `us-east-1`. Backup que só existe na região que caiu não é backup.
- **Object Lock em modo compliance** (governance para o time de dados): protege contra ransomware e contra `DELETE` acidental — nem o root apaga antes do prazo.
- **SSE-KMS** com chave gerenciada, rotação anual.
- **Versionamento** ligado, para sobrescrita acidental ser reversível.

### Automação e alarme

- **EventBridge Scheduler** → **ECS task** rodando `backup-all.sh` (em vez de cron numa EC2 que alguém precisa manter viva).
- **CloudWatch alarm** em `pgbackrest info` sem full nas últimas 30h → SNS → PagerDuty.
- **A métrica que mais importa não é "o backup rodou", é "o restore funcionou".** `restore-drill.sh` roda **semanalmente em ambiente isolado**, e o alarme dispara se ele falhar ou se o RTO passar de 5 minutos. Backup que nunca foi restaurado é hipótese, não garantia.

### Se o TimescaleDB estiver no Timescale Cloud

O gerenciado já faz backup contínuo com PITR — o pgBackRest próprio deixa de ser necessário para o principal. Mas manteria um **export lógico periódico para bucket próprio**: backup que só existe dentro do fornecedor é risco de concentração, e não cobre o cenário de perder o acesso à conta.
