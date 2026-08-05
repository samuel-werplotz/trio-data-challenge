# Guia do Data Champion

Este guia é para quem vai **consultar** a plataforma analítica sem operá-la.
Ele responde: como pedir acesso, o que existe para consultar, o que cada tabela
responde (e o que ela **não** responde), como escrever uma query que não custa
caro, e para quem escalar quando algo não fecha.

Se você só quer um número rápido e não escreve SQL, pule para
[a API](#atalho-quem-não-escreve-sql).

---

## 1. Como pedir acesso

| Passo | O quê |
|---|---|
| 1 | Abra chamado para o time de Dados pedindo o perfil **`analytics_ro`** |
| 2 | Informe a ferramenta: cliente SQL, Hex, ou Grafana |
| 3 | O aprovador é o dono da plataforma de dados |

O perfil `analytics_ro` dá **leitura** sobre as tabelas analíticas e nada mais.
Ele **não** dá acesso a dados de titular (`accounts`) — esse é um perfil
separado, nominal e auditado. A matriz completa de quem lê o quê está em
[`SEGURANCA-E-GOVERNANCA.md`](SEGURANCA-E-GOVERNANCA.md); aqui basta saber que
o padrão é leitura do analítico, e o resto se pede com justificativa.

**Conexão** (ClickHouse):

| | |
|---|---|
| Host / porta nativa | `clickhouse` : `9000` |
| Porta HTTP | `8123` |
| Banco | `trio_analytics` |

---

## 2. O catálogo — o que existe e o que cada coisa responde

São **4 objetos**. Comece sempre pelas duas MVs; só desça para a raw quando
elas não bastarem.

### `daily_by_institution` — MV diária por instituição

Grão: **1 linha por (dia × instituição × tipo)**.

| Responde | Não responde |
|---|---|
| Volume e valor por instituição, por dia | Nada abaixo de 1 dia — para hora, use `status_funnel` |
| Ticket médio, P95 e P99 de **valor** | Percentil de **latência** (está no `status_funnel`) |
| Quantas liquidaram e quantas falharam no dia | *Quando* liquidou — não há timestamp aqui |
| Série histórica de 12 meses, barata | Transação individual — não há `external_id` |

### `status_funnel` — MV horária por status

Grão: **1 linha por (hora × tipo × instituição × status)**.

| Responde | Não responde |
|---|---|
| Quantas transações estão em cada status, por hora | **Transições** entre status — ver a limitação abaixo |
| Latência de liquidação: média, P50, P95 | Valor financeiro — não há coluna de `amount` |
| Recorte por hora do dia, para achar pico | Nada abaixo de 1 hora |

> ⚠️ **Limitação declarada: o funil mede estado, não transição.** A origem
> sobrescreve `status` a cada mudança e não guarda histórico. Uma transação que
> passou por `pending` → `failed` → `settled` aparece **só como `settled`**.
> Se a sua pergunta é "quantas *passaram* por falha", esta tabela não responde,
> e nenhuma outra na plataforma responde hoje.

### `transactions_raw` — o dado transação a transação

10 milhões de linhas, 12 meses, `ReplacingMergeTree`. Use quando precisar de
uma transação específica, de um recorte que as MVs não têm, ou de cruzar
colunas que não estão agregadas juntas.

| Responde | Não responde |
|---|---|
| Qualquer recorte sobre a transação individual | Dados do titular — **não há PII aqui**, por desenho |
| `external_id`, contas de origem/destino (por id) | Nome, documento ou contato do cliente |
| Metadados da transação | Reconciliação com saldo de conta — ver § 6 |

**A ordenação física é `(type, source_institution, hora, external_id)`.** Filtrar
nessa ordem é o que faz a query ser rápida — ver § 4.

### `dict_institutions` — o Dictionary de referência

15 instituições vindas do legado, atualizadas a cada 5 min pelo `ref-sync`.
Serve para trocar o código (`'237'`) pelo nome (`'Bradesco'`) **sem JOIN**.

> A chave é `String` com layout `COMPLEX_KEY_HASHED`, então o lookup exige
> `tuple(...)`: `dictGetOrDefault(..., tuple(source_institution), ...)`.
> Passar a chave sem `tuple()` devolve erro de tipo — é o tropeço mais comum.

---

## 3. Três queries-modelo

Todas foram executadas contra o cluster real; o tempo ao lado é a mediana de 3
execuções (a 1ª, fria, descartada).

### 3.1 — Volume por instituição no último mês · **5 ms**

O padrão mais comum: ler a MV diária. Repare no sufixo `-Merge`.

```sql
SELECT
    day,
    source_institution,
    countMerge(tx_count)        AS transacoes,   -- count      -> countMerge
    sumMerge(total_amount)      AS volume,       -- sum        -> sumMerge
    countIfMerge(settled_count) AS liquidadas    -- countIf    -> countIfMerge (!)
FROM trio_analytics.daily_by_institution
WHERE day >= today() - 30
  AND type = 'pix'
GROUP BY day, source_institution
ORDER BY day DESC, volume DESC;
```

**O detalhe que derruba todo mundo:** o sufixo `-Merge` tem que casar com a
função que **gravou** o estado. `settled_count` foi gravada com `countIf`, então
lê-se com `countIfMerge` — usar `countMerge` devolve
`Aggregate function count requires zero or one argument`.
Confira com `SHOW CREATE TABLE` quando estiver em dúvida: o tipo da coluna diz
qual função usar (`AggregateFunction(countIf, ...)` → `countIfMerge`).

### 3.2 — Nome da instituição sem JOIN · **4 ms**

```sql
SELECT
    source_institution AS codigo,
    dictGetOrDefault(
        'trio_analytics.dict_institutions',
        'name',
        tuple(source_institution),        -- COMPLEX_KEY exige tuple()
        concat('(desconhecida ', source_institution, ')')
    )                                AS instituicao,
    countMerge(tx_count)             AS transacoes,
    round(sumMerge(total_amount), 2) AS volume
FROM trio_analytics.daily_by_institution
WHERE day >= today() - 7
GROUP BY source_institution
ORDER BY volume DESC;
```

**Sempre `dictGetOrDefault`, nunca `dictGet` puro.** Com o default explícito,
um código sem correspondência aparece como `(desconhecida 999)` em vez de vazio
— e você *vê* que faltou referência, em vez de achar que o dado sumiu.

Medido contra a JOIN equivalente no PostgreSQL: **4 ms × 15 ms** no lookup por
linha, **11 ms × 147 ms** no `GROUP BY` sobre 10M. O Dictionary vive em memória
(15 linhas, 43 KiB); a JOIN vai ao legado a cada execução.

### 3.3 — Descer para a raw sem varrer 12 meses · **6 ms**

```sql
SELECT
    toStartOfHour(created_at)        AS hora,
    count()                          AS transacoes,
    round(sum(amount), 2)            AS volume,
    round(avg(settlement_seconds), 1) AS media_liquidacao_s
FROM trio_analytics.transactions_raw
WHERE created_at >= toDateTime('2026-07-01 00:00:00')   -- poda a partição
  AND created_at <  toDateTime('2026-07-02 00:00:00')
  AND type = 'pix'                                      -- 1ª coluna do ORDER BY
  AND source_institution = '237'                        -- 2ª coluna do ORDER BY
GROUP BY hora
ORDER BY hora;
```

Lê **8.192 linhas** (um granule) das 10 milhões. Os três filtros trabalham
juntos: `created_at` elimina 11 das 12 partições, `type` e `source_institution`
usam o índice primário na ordem em que ele foi construído.

**O contraexemplo, medido:** a mesma pergunta escrita com
`WHERE toString(created_at) LIKE '2026-07-01%'` lê **6.094.848 linhas em
216 ms** — 36× mais lento, 744× mais dado, resposta idêntica. Envolver a coluna
numa função impede a poda de partição. **Compare com a coluna crua, sempre.**

---

## 4. MV ou raw? — regra de decisão

```
A pergunta cabe em (dia × instituição × tipo)?      → daily_by_institution
A pergunta é sobre status ou latência, por hora?    → status_funnel
Precisa de transação individual ou coluna solta?    → transactions_raw + filtro de tempo
Só quer o nome da instituição?                      → dictGetOrDefault
```

Na dúvida, comece pela MV: ela custa uma fração da raw porque foi agregada na
ingestão. Descer para a raw é legítimo — só faça isso **com filtro de data**.

### As 4 armadilhas, com o erro literal

| Sintoma | Causa | Correção |
|---|---|---|
| Coluna vem como binário ilegível | Leu estado agregado sem `-Merge` | `countMerge(tx_count)`, não `tx_count` |
| `Aggregate function count requires zero or one argument` | Sufixo errado: coluna é `countIf` | Use `countIfMerge` |
| `Aggregate function ... is found inside another aggregate function` | Agregação aninhada, ex. `sum(countMerge(x))` | Faça o `-Merge` numa subconsulta e o `sum` fora |
| MV e raw discordam na contagem | MV é **gatilho de inserção**, não view que recalcula | Ver abaixo |

> **A armadilha que mais custou neste projeto.** MV no ClickHouse **não**
> recalcula quando a origem muda: ela dispara na inserção. Duas consequências
> reais, ambas já ocorridas aqui: (1) rodar `INSERT SELECT` de backfill numa MV
> já ativa **duplica** o que ela capturou sozinha; (2) apagar linha só na raw
> deixa o agregado **para trás**. Se você encontrar divergência entre a MV e a
> raw, **não é erro da sua query** — reporte (§ 7).

---

## 5. Limites e custo de query

O perfil `analytics_ro` roda com teto. Não é burocracia: uma query sem filtro
sobre 10M compete com o pipeline que alimenta os painéis de todo mundo.

| Limite | Valor sugerido | O que você vê ao estourar |
|---|---|---|
| `max_execution_time` | `60` s | `Code: 159 ... Timeout exceeded: elapsed 1.003 seconds, maximum: 1. (TIMEOUT_EXCEEDED)` |
| `max_rows_to_read` | `50000000` | `Code: 158 ... Limit for rows (controlled by 'max_rows_to_read' setting) exceeded, max rows: 1.00 million, current rows: 10.00 million. (TOO_MANY_ROWS)` |
| `max_memory_usage` | `4 GiB` | `Code: 241 ... Memory limit (for query) exceeded: would use 98.66 MiB ..., maximum: 95.37 MiB. (MEMORY_LIMIT_EXCEEDED)` |
| `max_bytes_before_external_group_by` | metade do `max_memory_usage` | Sem erro — o `GROUP BY` passa a usar disco e fica mais lento |

*(As mensagens acima foram capturadas executando cada limite contra o cluster,
com valores propositalmente baixos para forçar a falha.)*

**Estourou um limite? Antes de pedir exceção**, tente nesta ordem: (1) filtrar
por data; (2) trocar a raw por uma MV; (3) reduzir o `GROUP BY`. Na prática a
maioria das queries pesadas é uma consulta de MV escrita contra a raw.

Se ainda assim precisar, peça exceção ao time de Dados dizendo **qual limite,
qual query e por quê** — exceção pontual por sessão é comum e barata.

---

## 6. O que a plataforma analítica não responde

**Reconciliação que dependa de dados da conta não é respondível aqui.** A tabela
`accounts` — a única com PII — **nunca vai para o ClickHouse**, por desenho: o
motor analítico é livre de dado pessoal, o que simplifica LGPD e reduz a
superfície de auditoria. `transactions_raw` referencia o titular apenas por
`source_account_id` (um inteiro).

Consequência prática: perguntas do tipo *"conciliar transações com o saldo/perfil
da conta"* precisam do TimescaleDB, não do ClickHouse.

| Caminho | Quando usar |
|---|---|
| API (`/ops/...`, `/institutions/...`) | Agregado pronto, sem PII — cobre a maioria dos casos |
| Acesso ao TimescaleDB com perfil restrito | Precisa mesmo cruzar com dado de conta; acesso nominal e auditado |

É um **trade-off assumido**, não um esquecimento: trocamos uma pergunta menos
frequente por um motor analítico sem dado pessoal.

---

## Atalho: quem não escreve SQL

A **API** já serve os agregados em JSON, com cache de 10s:

```bash
curl -s localhost:8000/ops/volume-now
curl -s "localhost:8000/institutions/237/health?hours=24"
```

Os **4 dashboards do Grafana** (`localhost:3000`) cobrem TimescaleDB,
ClickHouse, pipeline e legado.

### Hex

O PDF do desafio cita o Hex como ferramenta dos Data Champions. O caminho
previsto:

| | |
|---|---|
| Conector | ClickHouse nativo |
| Host / porta | endpoint do ClickHouse : `9000` (produção: **via PrivateLink**, sem passar pela internet) |
| Banco | `trio_analytics` |
| Usuário | `analytics_ro` — nunca o usuário da aplicação |
| Fontes a expor | `daily_by_institution` e `status_funnel`; a raw só sob demanda |

**Escreva o notebook contra a MV, não contra a raw.** Notebook tende a reexecutar
a célula a cada interação, e uma query de raw sem filtro reexecutada em loop é a
forma mais fácil de saturar o cluster.

> **Declaração honesta:** a integração com Hex **não foi executada** — não há
> conta de Hex neste ambiente. O que está acima é o caminho de conexão e a
> convenção de uso; validar exigiria provisionar o PrivateLink e uma conta, o
> que está fora do escopo (nenhuma AWS real é provisionada neste desafio).

---

## 7. Escalonamento

| Situação | O que fazer antes | Para quem | Prazo esperado |
|---|---|---|---|
| **Query lenta** (> 60 s ou estourou limite) | Tente as 3 correções do § 5 | Time de Dados, com a query junto | 1 dia útil |
| **Dado parece errado** | Confira se a pergunta é do § 4 (MV × raw) ou do § 6 (`accounts`) | Time de Dados — **com prioridade**, pode ser divergência MV/raw | mesmo dia |
| **Painel travado no passado** | Veja se o pipeline está parado: `curl -s localhost:8002/metrics \| grep refsync` | Plantão de dados — é incidente, não dúvida | imediato |
| **Acesso negado** | Confirme o perfil pedido | Dono da plataforma de dados | 1 dia útil |
| **Preciso de dado de titular** | Leia o § 6 | Dono da plataforma + Segurança (acesso nominal e auditado) | 3 dias úteis |

**Dado que parece errado escala rápido de propósito.** A divergência mais provável
— MV fora de sincronia com a raw — é invisível para quem consulta e precisa ser
corrigida na origem, não contornada na query.
