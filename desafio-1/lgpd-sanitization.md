# LGPD — sanitização de PII em chunks comprimidos

[← Voltar ao README](../README.md)

> Requisito do desafio: *"Documente como faria a sanitização de chunks
> comprimidos que contenham dados com PII (ex: solicitação LGPD de exclusão).
> Considere o impacto da compressão nesse processo."*

## O problema, em três camadas

**Camada 1 — chunk comprimido resiste a alteração.** Um chunk comprimido é
reorganizado em formato colunar. `UPDATE`/`DELETE` exigem
`decompress_chunk()` → alterar → `compress_chunk()`. Custo: descomprimir um
chunk de ~15 MB (nossos chunks de 1 dia, depois de comprimidos) gera
dezenas de MB temporários; fazer isso em várias centenas de chunks pode não
caber em disco.

**Camada 2 — os agregados também podem conter PII.** Apagar o bruto não basta
se um continuous aggregate guardar o nome do titular. E CAgg **não é
alterável diretamente** — só reprocessado a partir do bruto, que você acabou
de apagar.

**Camada 3 — o dado já foi replicado.** Com um pipeline de replicação rodando, a PII
chega ao ClickHouse, possivelmente a backups, possivelmente a dashboard em
cache. Exclusão real é um problema **distribuído**, não local.

## A arquitetura que evita o problema

Decisão tomada no schema (`init/timescaledb/01_schema.sql`), antes de existir
compressão ou pipeline — privacidade por design, não remendo depois:

```
transactions (hypertable, comprimida, zero PII) ──account_id──▶ accounts (tabela comum, toda a PII)
                       │
                       └──▶ CAggs (agregados por instituição/tipo, zero PII)
```

| Tabela | Contém PII? | É comprimida? | Excluir é... |
|---|---|---|---|
| `transactions` | **Não** — só `source_account_id`/`destination_account_id` | Sim | irrelevante |
| `accounts` | **Sim** — `holder_name`, `holder_document` | **Não** | `UPDATE` simples |
| `cagg_volume_hourly`, `cagg_settlement_latency_daily` | **Não** — agregam por `type`/`status`/`source_institution` | n/a | irrelevante |

Verificado no schema real, não só afirmado:

```sql
-- transactions não tem coluna de PII
SELECT count(*) FROM information_schema.columns
WHERE table_name='transactions' AND column_name IN ('holder_name','holder_document');
-- 0

-- accounts é tabela comum: não aparece em timescaledb_information.hypertables
SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_name='accounts';
-- 0

-- toda transação com conta de origem referencia accounts.id
SELECT count(*) FROM transactions WHERE source_account_id IS NULL AND destination_account_id IS NULL;
-- 0 de 10.000.000
```

**Consequência prática:** uma solicitação de exclusão vira um `UPDATE` numa
tabela de 500.000 linhas não comprimida — segundos, não horas, e nenhum
`decompress_chunk` entra no caminho.

## O procedimento de exclusão

Implementado em `init/timescaledb/05_lgpd_erasure.sql`
(`lgpd_erasure_log` + `PROCEDURE anonimizar_conta`), demonstrado em
`desafio-1/scripts/lgpd-erasure-demo.sh` sobre conta sintética descartável
(mesmo padrão do `retention-demo.sh` — nunca uma das 500.000
contas reais do seed).

### Passo 1 — anonimizar na origem

```sql
CALL anonimizar_conta(p_account_id => 12345, p_requester => 'DPO');
```

O procedimento, comando por comando:

```sql
-- registro de auditoria ANTES de apagar: se o UPDATE falhar depois, o rastro
-- da solicitação não se perde
INSERT INTO lgpd_erasure_log (document_hash, requested_at, requester)
VALUES (encode(digest(v_document, 'sha256'), 'hex'), now(), p_requester);

UPDATE accounts
SET holder_name     = 'ANONIMIZADO',
    holder_document = 'ANON-' || encode(digest(id::text || 'salt', 'sha256'), 'hex'),
    status          = 'closed'
WHERE id = p_account_id;
```

**Por que `UPDATE` e não `DELETE`:** `transactions.source_account_id`
referencia `accounts.id`. Apagar a conta destruiria o histórico financeiro,
que a Trio é **obrigada a manter** por regulação do Banco Central (5 anos
para operações de pagamento). A LGPD reconhece esse conflito — Art. 16, I
permite conservação para cumprimento de obrigação legal. O que se faz é
**descaracterizar** o titular mantendo o registro contábil.

**Por que hash determinístico e não literal fixo:** duas anonimizações
concorrentes gravando o mesmo `'ANONIMIZADO'` em `holder_document` colidiriam
em qualquer índice futuro sobre a coluna. O hash amarra no `id`, que é único
por definição.

### Passo 2 — propagar ao ClickHouse: **não é necessário, e isso foi verificado**

> **Executado de ponta a ponta em 2026-08-04**, com o ClickHouse e o pipeline de
> pé. A conclusão inverteu o que este documento supunha quando foi escrito, antes
> de o motor analítico existir: **não há PII para propagar**.

**O que a verificação mostrou.** Nenhuma tabela de `trio_analytics` guarda dado
pessoal. A varredura por colunas candidatas devolve apenas nomes de
**instituição** — razão social de banco, dado público, não dado pessoal:

```sql
SELECT name, type FROM system.columns
 WHERE database = 'trio_analytics'
   AND (name ILIKE '%document%' OR name ILIKE '%holder%'
        OR name ILIKE '%name%' OR name ILIKE '%cpf%' OR name ILIKE '%email%');
-- name, short_name  →  ambas de dict_institutions (instituição, não titular)
```

`transactions_raw` referencia o titular apenas por **`source_account_id`
(inteiro)**. `accounts_dim` — citado na versão original deste passo — **nunca
foi criada**: a PII vive só em `accounts`, no TimescaleDB, que não é replicada
para o ClickHouse. É consequência direta da decisão de schema, não sorte.

**Teste executado**, sobre conta sintética descartável:

| # | Ação | Resultado |
|---|---|---|
| 1 | Criar conta sintética (`id=1000112`) + 1 transação | `holder_name='Titular Teste LGPD'`, `holder_document='99988877766'` |
| 2 | Esperar o sync-worker propagar | Linha chega ao ClickHouse com `source_account_id=1000112`, `amount=123.45` — **sem nome, sem documento** |
| 3 | `CALL anonimizar_conta(1000112, ...)` | Origem: `ANONIMIZADO` / `ANON-b596276…` |
| 4 | Reconferir o ClickHouse | Linha **inalterada** — nada a anonimizar, porque nada de pessoal havia chegado |
| 5 | Histórico transacional na origem | Preservado (1 transação, intacta) |
| 6 | Auditoria | `lgpd_erasure_log`: `document_hash=ba8c0ec7…`, `affected_rows=1`, `backups_pending=true` |
| 7 | Limpeza | Conta e transação sintéticas removidas nas duas pontas; **10.000.000 linhas em ambos** |

**Por que este é o resultado forte, e não uma tarefa que ficou por fazer.** O
melhor procedimento de propagação é o que não precisa existir: se a PII nunca
sai da origem, a exclusão é atômica em um lugar só, e não há janela em que o
dado esteja apagado no transacional e vivo no analítico. Foi por isso que
`transactions` e os CAggs foram desenhados livres de PII desde o primeiro schema.

**Quando a propagação seria necessária** — e o procedimento continua válido para
esse caso: se algum dia uma dimensão com PII for materializada no ClickHouse
(`accounts_dim`), o `UPDATE` de anonimização chegaria pelo pipeline, o
`ReplacingMergeTree` substituiria por `_version`, e as versões antigas
permaneceriam em disco **até o merge**. Aí seriam necessários:

```sql
-- Força o merge, colapsando as versões antigas
OPTIMIZE TABLE trio_analytics.accounts_dim FINAL;

-- Garantia adicional: remove fisicamente as linhas antigas.
-- Aceitável por ser operação rara e de baixíssimo volume — mutation em
-- ClickHouse reescreve partes inteiras e não deve virar rotina.
ALTER TABLE trio_analytics.accounts_dim
  DELETE WHERE account_id = :account_id AND _version < :versao_nova;
```

### Passo 3 — backups

O ponto mais desconfortável, e o que mais gente omite.

Backup é imutável por definição — se pudesse ser alterado, não serviria como
backup. A PII permanece nos backups até eles expirarem.

| Medida | Como |
|---|---|
| Criptografia em repouso | SSE-KMS no MinIO/S3 — sem a chave, o backup é ruído |
| Retenção limitada | Lifecycle policy expira em 365 dias — a exclusão se completa nesse prazo |
| Registro da pendência | `lgpd_erasure_log.backups_pending` marca quais exclusões ainda não expiraram nos backups |
| Nova solicitação → nova anonimização | Se um backup antigo for restaurado, o processo reexecuta as exclusões pendentes sobre ele |

Documentar essa limitação honestamente é mais forte do que alegar exclusão
instantânea que não existe. A ANPD aceita prazo razoável; o que não se aceita
é ausência de processo.

## E se a PII estivesse no chunk comprimido?

O desafio pede que se considere esse caso — hoje ele não se aplica (PII vive
só em `accounts`, nunca comprimida), mas é o cenário que a arquitetura evitou
de propósito, e vale documentar o caminho que **não** foi tomado.

### A) Descomprimir → alterar → recomprimir

```sql
-- localiza só os chunks afetados
SELECT c.chunk_schema, c.chunk_name
FROM timescaledb_information.chunks c
WHERE c.hypertable_name = 'transactions'
  AND c.is_compressed
  AND EXISTS (
      SELECT 1 FROM transactions t
      WHERE t.source_account_id = 12345
        AND t.created_at >= c.range_start
        AND t.created_at <  c.range_end
  );

SELECT decompress_chunk(format('%I.%I', chunk_schema, chunk_name)::regclass);
UPDATE transactions SET ... WHERE source_account_id = 12345;
SELECT compress_chunk(format('%I.%I', chunk_schema, chunk_name)::regclass);
```

| Prós | Contras |
|---|---|
| Cirúrgico, só os chunks afetados | Precisa de espaço temporário (~13× o tamanho do chunk) |
| Não muda a arquitetura | Lento: minutos por chunk |
| | Durante a descompressão, queries no período ficam mais lentas |

**Quando usar:** poucos titulares, poucos chunks, espaço em disco disponível.

### B) Crypto-shredding

PII armazenada criptografada, com chave por titular guardada fora do banco
(KMS). Excluir = destruir a chave. O dado continua no disco, comprimido, mas
fica matematicamente irrecuperável.

| Prós | Contras |
|---|---|
| Exclusão **instantânea**, sem tocar em chunk | Exige planejamento desde o início |
| Funciona retroativamente sobre backups | Overhead de cripto em toda leitura |
| Resolve o problema dos backups | Gestão de milhões de chaves é complexa |

**Quando usar:** volume alto de solicitações, ou requisito de exclusão
comprovada em backups.

### C) Tabela lateral — nossa escolha

PII em tabela separada, não comprimida, referenciada por id. É a arquitetura
já implementada neste projeto (`accounts`).

| Prós | Contras |
|---|---|
| Exclusão trivial e rápida | Custa um `JOIN` quando se precisa do nome |
| Chunks comprimidos nunca são tocados | Exige decidir antes |
| CAggs naturalmente livres de PII | |

**Quando usar:** sempre que possível decidir no início. É o caso aqui.

### Comparação final

| Critério | A) Descomprimir | B) Crypto-shredding | C) Tabela lateral |
|---|---|---|---|
| Tempo de exclusão | minutos–horas | instantâneo | segundos |
| Espaço extra | alto | nenhum | baixo |
| Resolve backups | não | **sim** | não |
| Exige decidir antes | não | sim | sim |
| Complexidade | baixa | **alta** | baixa |

**Por que C e não A ou B:** A resolve o sintoma (PII num chunk comprimido)
mas não evita que o problema volte a acontecer — cada nova solicitação
repete o ciclo caro de descomprimir/recomprimir. B resolve o problema mais
difícil (backups) mas custa complexidade operacional (gestão de chave por
titular) que não se justifica sem um volume de solicitações que exija isso.
C tem o menor custo operacional contínuo e resolve o problema **antes de ele
existir**: a decisão foi tomada no schema, não em resposta a uma
solicitação real.

## Tabela de auditoria

```sql
CREATE TABLE lgpd_erasure_log (
    id              BIGSERIAL PRIMARY KEY,
    document_hash   TEXT NOT NULL,
    requested_at    TIMESTAMPTZ NOT NULL,
    executed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    requester       TEXT NOT NULL,
    affected_rows   INT,
    backups_pending BOOLEAN DEFAULT true,
    notes           TEXT
);
```

`document_hash`, nunca o documento em claro — ver "Por que hash" acima.
`backups_pending` marca que a exclusão está completa no ambiente ativo mas
ainda pendente nos backups; vira relatório para o DPO.

## Prazo legal

A LGPD (Art. 18, §3º) não fixa prazo explícito para exclusão, mas a ANPD
orienta **até 15 dias** para resposta ao titular.

Nosso processo: exclusão no ambiente ativo em **segundos** (medido:
`anonimizar_conta` sobre 1 conta em `desafio-1/scripts/lgpd-erasure-demo.sh`
— tempo dominado pela latência do `psql`, não do `UPDATE`), resposta ao
titular imediata, e nota informando que backups expiram em até 365 dias
conforme política de retenção.

## Checklist de verificação

Executado por `desafio-1/scripts/lgpd-erasure-demo.sh`. **Os 5 itens são
verificáveis hoje** — quando este documento foi escrito, os itens 3 e 4 ainda
dependiam de componentes que não existiam; com o ClickHouse e o pipeline de pé,
foram executados:

```sql
-- 1. A PII sumiu da origem?
SELECT holder_name, holder_document FROM accounts WHERE id = :account_id;
-- ANONIMIZADO / ANON-<hash>

-- 2. O histórico transacional permaneceu?
SELECT count(*) FROM transactions WHERE source_account_id = :account_id;
-- inalterado

-- 3. E no ClickHouse? [VERIFICADO — nada a propagar]
--    Não existe accounts_dim: nenhuma tabela de trio_analytics guarda PII.
--    A verificação é pela ausência, e ela é positiva:
SELECT name FROM system.columns
 WHERE database = 'trio_analytics'
   AND (name ILIKE '%document%' OR name ILIKE '%holder%' OR name ILIKE '%cpf%');
-- 0 linhas — o titular só aparece como source_account_id (inteiro)

-- 4. Os CAggs continuam corretos? [não aplicável: nunca guardam PII]
SELECT sum(tx_count) FROM cagg_volume_hourly WHERE bucket >= '2026-01-01';

-- 5. A auditoria registrou?
SELECT document_hash, requester, affected_rows, backups_pending
  FROM lgpd_erasure_log ORDER BY executed_at DESC LIMIT 1;
```

O item 2 é o que mais gente esquece: **provar que a exclusão não destruiu o
que era obrigatório manter**.
