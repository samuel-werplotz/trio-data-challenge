# Premissas verificadas — etapa E1

Aplicação da regra [[D07]]: **nenhuma afirmação sobre comportamento de ferramenta de terceiro entra em decisão de arquitetura sem comando executado e saída colada.**

Motivo da regra: três premissas não verificadas já custaram retrabalho neste projeto — `timescaledb_toolkit` ausente da imagem (etapa 08), tag `debezium/connect:2.7` inexistente (etapa 13) e `publish_via_partition_root` sobre hypertable (etapa 13, custou ~1 dia e a troca de abordagem).

Verificado em **2026-08-04**, antes de escrever qualquer linha do `sync-worker`.

---

## P1 — O trigger de `updated_at` dispara em todo `UPDATE`, inclusive via chunk

**Por que importa:** o watermark do micro-batch lê `WHERE updated_at >= marca`. Se o trigger não disparar, a mudança **some silenciosamente** — a pior falha possível do desenho, porque não gera erro.

> [!check] VERIFICADO — o trigger dispara, e existe nos 338 chunks
> ```sql
> SELECT tgname, tgenabled FROM pg_trigger
>  WHERE tgrelid='transactions'::regclass AND NOT tgisinternal;
> ```
> → `trg_transactions_updated_at | O`  (O = habilitado)
>
> Teste prático — `UPDATE` através da hypertable:
> ```
> ANTES:  2026-08-04 12:46:35.977278+00
> UPDATE 1
> DEPOIS: 2026-08-04 12:47:16.187782+00 | status=settled
> ```
>
> E o que de fato decide, dado que a escrita cai no chunk e não na tabela-mãe:
> ```sql
> SELECT count(*) FROM pg_trigger t JOIN pg_class c ON c.oid=t.tgrelid
>  WHERE c.relname LIKE '_hyper_1_%_chunk' AND t.tgname='trg_transactions_updated_at';
> ```
> → **338** — o TimescaleDB propaga o trigger para todo chunk, inclusive os criados depois.

**Conclusão:** watermark por `updated_at` é viável. **Esta é a premissa que sustenta o E2 inteiro** — foi a primeira a ser testada de propósito.

---

## P2 — ❌ REFUTADA: não existe índice em `updated_at`

**Por que importa:** a janela do watermark roda a cada ~10s. Sem índice, é varredura completa a cada ciclo.

> [!failure] REFUTADA — a consulta do watermark faz Seq Scan de 10M + Sort
> Índices existentes em `transactions`: `transactions_pkey (id, created_at)`, `transactions_created_at_idx (created_at DESC)`, `idx_tx_institution_created`, `idx_tx_dup_detection`. **Nenhum cobre `updated_at`.**
>
> ```sql
> EXPLAIN (ANALYZE, BUFFERS) SELECT id FROM transactions
>  WHERE updated_at >= now() - interval '30 seconds' ORDER BY updated_at, id LIMIT 50000;
> ```
> ```
> Limit  (cost=520708.14..526541.88 rows=50000) (actual rows=1)
>   Buffers: shared hit=99275 read=2119 dirtied=921
>   ->  Gather Merge  (rows=10555511)   ← estimativa: a tabela inteira
>         ->  Sort  (Sort Key: updated_at, id)
> ```
> **101.394 buffers para devolver 1 linha.** A cada 10 segundos, isso inviabiliza o banco.

**Ação tomada:** índice criado (E1).

```sql
-- CONCURRENTLY não é aceito: "hypertables do not support concurrent index creation".
-- Sem ele o TimescaleDB propaga para os 338 chunks em 1,4s — verificado.
CREATE INDEX IF NOT EXISTS idx_tx_updated_at ON transactions (updated_at, id);
```

Propagação confirmada: `338` chunks com índice em `updated_at`.

### P2b — ⚠️ O índice sozinho NÃO resolveu: a query do worker precisa de predicado duplo

Criado o índice e rodado `ANALYZE`, o plano **continuou em Seq Scan** (85.587 buffers). A causa aparece no plano:

```
Custom Scan (ConstraintAwareAppend)
  Hypertable: transactions
  Chunks excluded during startup: 0     ← nenhum chunk descartado
```

**Motivo:** a hypertable é particionada por **`created_at`**. Um filtro só em `updated_at` não dá ao planner como excluir chunk nenhum — ele precisa abrir os 338 e conferir. O índice existe em cada chunk, mas abrir 338 índices é pior que varrer.

**Solução — filtrar também por `created_at` na mesma query:**

```sql
SELECT ... FROM transactions
 WHERE updated_at >= :watermark - interval '30 seconds'
   AND created_at >= :watermark - interval '7 days'   -- ATIVA A EXCLUSÃO DE CHUNKS
 ORDER BY updated_at, id
 LIMIT 50000;
```

> [!check] MEDIDO — antes e depois
> | Versão | Buffers | Plano |
> |---|---|---|
> | Só `updated_at` | **85.587** | Seq Scan + Sort nos 338 chunks |
> | `updated_at` **+** `created_at` | **17** | `Index Scan` + `Merge Append` em 1 chunk |
>
> **≈5.000× menos I/O.** O `Merge Append` sobre índices já ordenados também elimina o Sort — o `ORDER BY updated_at, id` sai de graça.

**A premissa que o predicado duplo assume**, e que também foi medida:

```sql
SELECT max(updated_at - created_at) FROM transactions WHERE status='settled';  → 00:00:00
```

Hoje `updated_at` nunca se afasta de `created_at` — o seed não simula liquidação tardia. A margem de **7 dias** é folga deliberada para o caso de uma transação antiga ser atualizada (estorno, reconciliação tardia).

> [!danger] Limite conhecido deste desenho — declarar no ADR
> Uma transação com `created_at` **anterior à janela de 7 dias** que sofra `UPDATE` **não é capturada**. Mitigações possíveis, em ordem de custo: (a) alargar a janela de `created_at`; (b) uma varredura de reconciliação diária sem o filtro de `created_at`; (c) tabela `outbox` com `created_at` próprio, que elimina o problema pela raiz.
> **Escolha para o E2:** janela de 7 dias + varredura diária completa. Cobre o caso real e mantém o ciclo barato.

> [!note] Este achado justifica a própria regra D07 duas vezes
> A auditoria assumiu "index scan barato". Errado **duas vezes**: não havia índice, e criar o índice **não bastava** — faltava entender que o particionamento é por outra coluna. Descoberto depois do worker pronto, o sintoma seria "pipeline lento sob carga" e a investigação começaria no código Python, não no plano de execução. Custo de verificar: 10 minutos.

---

## P3 — ❌ REFUTADA: `pgbackrest` não existe na imagem

```
docker exec trio-timescaledb sh -c "command -v pgbackrest"   → AUSENTE
```

**Consequência já observada:** o compose tinha `archive_mode=on` com `archive_command=pgbackrest ...`. O comando falhava com `exit 127` a cada segmento, o Postgres **não recicla WAL não-arquivado**, e o `pg_wal` chegou a **17,7 GB** (volume total de 20,8 GB para 3,1 GB de dado real).

**Ação tomada no E0:** `archive_mode=off` com o motivo comentado no compose. E4 religa junto com o repositório de backup real.

> [!danger] Arquivamento quebrado é pior que arquivamento desligado
> Dá a ilusão de haver PITR **e** enche o disco. As duas falhas ao mesmo tempo.

**Opções para o E4:** instalar pgBackRest via `Dockerfile` próprio (imagem derivada), ou usar `pg_basebackup` + `pg_dump -Fc`, ambos presentes (P6). Decisão fica para o E4, agora com o custo real de cada uma visível.

---

## P4 — ❌ REFUTADA: `clickhouse-backup` não existe na imagem

```
docker exec trio-clickhouse sh -c "command -v clickhouse-backup"   → AUSENTE
```

---

## P5 — O `BACKUP` nativo do ClickHouse existe e serve de alternativa

> [!check] VERIFICADO — comando existe, só falta configurar o disco de destino
> ClickHouse `v24.8.14.39-stable`.
> ```sql
> BACKUP TABLE trio_analytics.status_funnel TO Disk('backups','e1_teste.zip');
> ```
> → `Code: 318. The 'backups.allowed_disk' configuration parameter is not set`
>
> O erro é de **configuração**, não de ausência de recurso — o motor de backup está no servidor. Discos hoje: só `default` em `/var/lib/clickhouse/`.

**Ação para o E4:** declarar `<backups><allowed_disk>` na configuração. Evita instalar binário externo e é a via nativa e suportada.

---

## P6 — `pg_dump` disponível nas duas instâncias PostgreSQL

> [!check] VERIFICADO
> ```
> trio-timescaledb      → pg_dump (PostgreSQL) 16.14
> trio-postgres-legado  → pg_dump (PostgreSQL) 16.14 (Debian 16.14-1.pgdg12+1)
> ```

Garante o backup **lógico** dos dois PostgreSQL sem depender de nada externo. O PDF § 5.2 A.1 pede tipo declarado por banco (físico/lógico, full/incremental) — dá para cumprir mesmo se o pgBackRest não entrar.

---

## Resumo

| # | Premissa | Veredito | Impacto |
|---|---|---|---|
| P1 | Trigger `updated_at` dispara, inclusive em chunk | ✅ **Confirmada** | E2 liberado |
| P2 | Índice em `updated_at` existe | ❌ **Refutada** | Criar índice **antes** do worker |
| P3 | `pgbackrest` na imagem | ❌ **Refutada** | `archive_mode=off`; E4 decide o caminho |
| P4 | `clickhouse-backup` na imagem | ❌ **Refutada** | Usar P5 |
| P5 | `BACKUP` nativo do ClickHouse | ✅ **Confirmada** | Via oficial do E4 |
| P6 | `pg_dump` nas duas instâncias | ✅ **Confirmada** | Backup lógico garantido |

**3 de 6 premissas refutadas.** Todas teriam virado bug em etapa posterior, com sintoma distante da causa. Custo total da verificação: ~10 minutos.
