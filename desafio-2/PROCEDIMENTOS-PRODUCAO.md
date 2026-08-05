# Procedimentos de produção — mudanças sem downtime

Dois procedimentos que o [`ADR.md`](ADR.md) referencia e que o PDF § 7 cobra
diretamente: **adicionar um consumidor sem impactar as aplicações** e **migrar
a engine de uma tabela ClickHouse em produção sem downtime**.

Os dois nasceram de erro real cometido neste projeto, não de leitura de blog. As
cicatrizes estão citadas com etapa e sintoma — é o que dá confiança de que o
passo existe por um motivo.

---

## 1. Novo consumidor (MV) sobre tabela quente

**Cenário:** alguém precisa de um agregado que não existe — digamos, volume por
par (instituição origem → destino) por hora. A tabela `transactions_raw` está
recebendo escrita do `sync-worker` a cada 10s e servindo consultas.

### As duas cicatrizes que moldam este procedimento

| Etapa | O que aconteceu | Lição |
|---|---|---|
| **12** | `INSERT SELECT` de backfill rodou numa MV **já ativa**. A MV capturou os 12 blocos mensais sozinha, e o backfill duplicou tudo: **20.000.000 agregados para 10.000.000 de linhas** | MV é gatilho: a partir do `CREATE`, ela já pega o que entra. Backfill só pode cobrir o que entrou **antes** |
| **16** | `ALTER TABLE ... DELETE` removeu linha da raw e **não** removeu o agregado. Raw em 10.000.000, MVs em 10.000.001 | Mudança na origem não propaga para a MV. Nos dois sentidos |

**A regra que sai das duas:** existe um instante — o `CREATE MATERIALIZED VIEW`
— que divide o dado em "a MV pega sozinha" e "preciso fazer backfill". Todo o
procedimento é sobre marcar esse instante com precisão e não sobrepor as duas
metades.

### Procedimento

**Passo 1 — criar a tabela de destino, sem a MV.**

```sql
CREATE TABLE trio_analytics.hourly_by_pair
(
    hour                    DateTime,
    source_institution      LowCardinality(String),
    destination_institution LowCardinality(String),
    tx_count                AggregateFunction(count, UInt64),
    total_amount            AggregateFunction(sum, Decimal(18,2))
)
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (source_institution, destination_institution, hour);
```

Nenhum impacto: tabela vazia, ninguém escreve nela.

**Passo 2 — anotar o instante de corte e criar a MV.**

```sql
-- Anote este valor. Ele é a fronteira do backfill.
SELECT now() AS corte;   -- ex.: 2026-08-05 02:00:00

CREATE MATERIALIZED VIEW trio_analytics.mv_hourly_by_pair
TO trio_analytics.hourly_by_pair
AS SELECT
    toStartOfHour(created_at) AS hour,
    source_institution,
    destination_institution,
    countState()              AS tx_count,
    sumState(amount)          AS total_amount
FROM trio_analytics.transactions_raw
GROUP BY hour, source_institution, destination_institution;
```

**Nunca com `POPULATE`.** `POPULATE` lê o histórico *e* perde o que for escrito
durante a leitura — é a pior combinação: demorado e com buraco. A partir daqui a
MV captura toda inserção nova.

**Passo 3 — backfill apenas do que é anterior ao corte.**

```sql
INSERT INTO trio_analytics.hourly_by_pair
SELECT
    toStartOfHour(created_at) AS hour,
    source_institution,
    destination_institution,
    countState(),
    sumState(amount)
FROM trio_analytics.transactions_raw
WHERE created_at < '2026-08-05 02:00:00'   -- o corte do passo 2
GROUP BY hour, source_institution, destination_institution;
```

**O `WHERE` é o procedimento inteiro.** Sem ele, este é exatamente o comando que
duplicou 10M na etapa 12. Faça o backfill **por partição** se o volume for
grande — um `INSERT SELECT` sobre 12 meses compete por memória com a ingestão.

**Passo 4 — validar antes de publicar.**

```sql
-- O agregado tem que bater com a raw. Note o -Merge na subconsulta:
-- sum(countMerge(...)) direto dá ILLEGAL_AGGREGATION.
SELECT sum(n) FROM (
  SELECT countMerge(tx_count) AS n
  FROM trio_analytics.hourly_by_pair
  GROUP BY hour, source_institution, destination_institution
);
SELECT count() FROM trio_analytics.transactions_raw;
```

Divergiu? **Não corrija por cima.** Trunque a tabela de agregação (a raw fica
intacta), reveja o corte e refaça o passo 3. Foi assim que a etapa 12 se
recuperou.

### Impacto nas aplicações existentes

| Dimensão | Efeito | Mitigação |
|---|---|---|
| **Leitura das MVs atuais** | Nenhum. Tabelas separadas, sem contenção de leitura | — |
| **Escrita na raw** | Cada `INSERT` passa a alimentar mais uma MV: **+1 gravação por lote** | Custo proporcional ao lote, não ao acumulado. Medido aqui: escrita de 5.800 linhas em ~1s com 2 MVs ativas |
| **Merges** | Mais uma tabela `AggregatingMergeTree` com merges próprios | Criar fora do pico. Vigiar `system.merges` e `parts` na primeira hora |
| **Backfill (passo 3)** | É o único passo pesado — compete por CPU e memória | Fazer por partição, fora do pico, com `max_execution_time` folgado |
| **Rollback** | `DROP VIEW mv_hourly_by_pair` para de alimentar; `DROP TABLE` remove o dado | Reversível a qualquer momento. A raw nunca é tocada |

> **Por que não precisa de janela de manutenção:** nenhum passo altera a
> `transactions_raw`, e a aplicação não lê a tabela nova até alguém apontá-la.
> O pior caso de erro é uma tabela de agregação com número errado, corrigível
> por `TRUNCATE` + backfill — sem perda de dado, porque a fonte da verdade é a
> raw (e, acima dela, o TimescaleDB).

---

## 2. Migrar a engine de uma tabela em produção sem downtime

**Cenário concreto e real neste projeto:** `transactions_raw` é
`ReplacingMergeTree` num nó único. Em produção ela precisa ser
`ReplicatedReplacingMergeTree` para ter réplica — é o risco nº 1 do
[sumário executivo](../docs/SUMARIO-EXECUTIVO.md).

**Não existe `ALTER TABLE ... MODIFY ENGINE`.** Trocar engine é mover dado para
uma tabela nova. O procedimento abaixo faz isso com a aplicação escrevendo o
tempo todo.

### Procedimento — tabela sombra + `EXCHANGE TABLES`

**Passo 1 — criar a sombra com a engine de destino.**

```sql
CREATE TABLE trio_analytics.transactions_raw_new
(
    -- schema IDÊNTICO ao original: mesmas colunas, tipos, codecs e MATERIALIZED
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/transactions_raw', '{replica}', _version
)
PARTITION BY toYYYYMM(created_at)
ORDER BY (type, source_institution, toStartOfHour(created_at), external_id)
TTL toDateTime(created_at) + toIntervalMonth(25);
```

`ORDER BY` e `PARTITION BY` **têm** que ser idênticos — se mudarem, isto deixa
de ser troca de engine e vira reescrita de dado, com outro procedimento e outro
risco.

**Passo 2 — dupla escrita.**

```sql
CREATE MATERIALIZED VIEW trio_analytics.mv_dupla_escrita
TO trio_analytics.transactions_raw_new
AS SELECT * FROM trio_analytics.transactions_raw;
```

A partir daqui, tudo que entra na antiga entra também na nova. **Anote o
instante** — mesma lógica do procedimento 1.

Alternativa se a aplicação for quem escreve: fazer o `sync-worker` escrever nas
duas. Mais controle, mais código. A MV é preferível por não exigir deploy.

**Passo 3 — backfill do histórico, por partição.**

```sql
-- Uma partição por vez: previsível, interrompível, e não estoura memória.
INSERT INTO trio_analytics.transactions_raw_new
SELECT * FROM trio_analytics.transactions_raw
WHERE toYYYYMM(created_at) = 202607
  AND created_at < '<instante do passo 2>';
```

Repetir por partição. Entre uma e outra, conferir `system.merges` — backfill que
empilha parts mais rápido do que o merge consegue consolidar leva a
`too many parts`, que aí sim vira incidente.

**Passo 4 — validar, partição a partição.**

```sql
SELECT toYYYYMM(created_at) AS p, count() AS n
FROM trio_analytics.transactions_raw  GROUP BY p ORDER BY p;

SELECT toYYYYMM(created_at) AS p, count() AS n
FROM trio_analytics.transactions_raw_new GROUP BY p ORDER BY p;
```

**Contagem por partição, não total.** Um total igual pode esconder uma partição
a mais e outra a menos. Para `ReplacingMergeTree`, comparar também
`count() FINAL` — versões duplicadas ainda não colapsadas inflam o número bruto
nas duas pontas de forma diferente.

**Critério de aborto, decidido antes:** qualquer partição divergente → **não
troca**. Investiga, corrige a partição, revalida.

**Passo 5 — a troca, atômica.**

```sql
EXCHANGE TABLES trio_analytics.transactions_raw
             AND trio_analytics.transactions_raw_new;
```

**`EXCHANGE TABLES` é atômico e é o coração do procedimento.** A alternativa —
`RENAME` em dois tempos (`raw` → `raw_old`, `raw_new` → `raw`) — tem uma janela
entre os dois comandos em que **a tabela `transactions_raw` não existe**, e toda
consulta nesse instante falha. Com `EXCHANGE`, nenhuma consulta vê ausência.

> Disponível a partir do ClickHouse 21.x; verificado nesta versão (24.8).

**Passo 6 — desmontar a dupla escrita e observar.**

```sql
DROP VIEW trio_analytics.mv_dupla_escrita;   -- a nova já é a principal
-- as MVs de agregação seguem apontando para o NOME transactions_raw,
-- que agora é a tabela nova: nada a mudar nelas.
```

Manter a antiga (agora `transactions_raw_new`) por **72 h**, como o rollback do
`migration-analysis.md`. Depois: `DROP TABLE`.

**Passo 7 — rollback.**

| Momento | Como reverter |
|---|---|
| Antes do passo 5 | `DROP` da sombra e da MV de dupla escrita. Nada aconteceu |
| Depois do passo 5, dentro de 72 h | `EXCHANGE TABLES` de novo — volta ao estado anterior de forma atômica. **O que entrou depois da troca está só na nova**, então recriar a dupla escrita no sentido inverso antes de reverter |
| Depois de 72 h | Não há rollback; há nova migração. Por isso a janela é explícita |

### Por que a réplica muda o passo 1

Com `Replicated*`, a tabela passa a depender do **ClickHouse Keeper** — que
precisa existir *antes*. Numa migração real a ordem é: subir o Keeper (3 nós) →
subir a 2ª réplica → só então o passo 1. Sem Keeper, o `CREATE` falha.

Custo dessa mudança: ver [`CUSTO-AWS.md`](../docs/CUSTO-AWS.md) — no cenário 10×
o ClickHouse já está dimensionado em 2 nós `m6i.4xlarge`.

---

## Resumo — o que os dois têm em comum

1. **Existe um instante de corte** que separa "o gatilho pega sozinho" de "eu
   faço backfill". Errar esse instante é a causa das duas cicatrizes.
2. **Valida-se por partição, nunca só pelo total.**
3. **A troca final é atômica** (`EXCHANGE TABLES`) ou não existe.
4. **A fonte da verdade nunca é tocada.** No pior caso se descarta a tabela nova
   e recomeça — o TimescaleDB e a raw continuam íntegros.
