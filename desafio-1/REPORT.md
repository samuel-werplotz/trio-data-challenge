# REPORT — Desafio 1: medições antes/depois

Dataset: 10.000.000 transações, 500.000 contas, 1.442.266 eventos de
reconciliação, 338 chunks (hypertable de 1 dia), 12 meses.

Protocolo de medição (S06 § O método): cada query roda 4 vezes; a 1ª é
descartada (aquece o cache); registra-se a **mediana das 3 seguintes**.
`EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` completo em
`desafio-1/queries/explains/qN_{before,after}.txt`.

## Tabela consolidada

| Query | Antes | Depois | Ganho | Técnica | Buffers antes→depois |
|---|---|---|---|---|---|
| Q1 — volume/valor por tipo+status, 6 meses | 12.115 ms | 23 ms | **521×** | CAgg `cagg_volume_hourly` | hit=95.670 → hit=500 |
| Q2 — divergências de reconciliação, 30 dias | 1.584 ms | 1.511 ms | **~1,05× (dentro do ruído)** | Índice parcial + covering `INCLUDE` | hit=157.938 read=170.126 → hit=124.389 read=167.109 |
| Q3 — top 20 instituições, 90 dias | 1.285 ms | 394 ms | **3,3×** | Índice covering `INCLUDE` | hit=53.407 read=0 → hit=23.317 read=0 |
| Q4 — duplicatas 5 min | 2.814 ms | 1.274 ms | **2,2×** | Self-join → window function `LAG()` | hit=31.712 read=150.693 → hit=15.792 temp=7.758 |
| Q3 via CAgg — top instituições, 90 dias | 1.285 ms | 3,4 ms | **383×** | CAgg `cagg_settlement_latency_daily` | hit=53.407 → hit=90 |
| Gapfill 48h | n/a | 49 buckets, 0 nulos | n/a | `time_bucket_gapfill` + `locf`/`interpolate` | — |

**A lição das duas linhas de CAgg:** a melhor otimização de uma agregação
recorrente não é acelerar a leitura do dado bruto — é não percorrer o dado
bruto. Índice não resolvia Q1: o `Seq Scan` sobre 2,7 milhões de linhas era
inerente à pergunta. O CAgg troca isso por uma varredura de ~79 mil buckets
horários já agregados, e os 95.670 buffers viram 500.

A Q3 aparece duas vezes de propósito. A versão da etapa 07 (índice covering,
3,3×) e a versão via CAgg (383×) respondem perguntas ligeiramente
diferentes — a do índice ranqueia por **volume financeiro**, a do CAgg por
**contagem de liquidadas**, porque `amount` não vive no CAgg de latência.
Não é a mesma query duas vezes: é o trade-off de qual pergunta o agregado
foi desenhado para responder.

### Por que a Q1 via CAgg é exata, e não aproximada

`sum(tx_count)` e `sum(total_amount)` são funções **somáveis**: o rollup de
hora para mês é aritmética exata, não amostragem. Verificado linha a linha
contra a query sobre o raw — **0 divergências**.

A ressalva que a verificação revelou: o corte precisa ser alinhado ao bucket.
Com `now() - INTERVAL '6 months'` cru (que cai no meio de uma hora), o mês da
borda divergia em ~193 linhas — o raw filtra a partir do minuto exato, o CAgg
inclui o bucket horário inteiro. Com `date_trunc('hour', ...)` a divergência
zera. É a classe de erro que não estoura em teste nenhum e aparece como
"o dashboard não bate com o relatório".

## O índice que não melhorou — Q2

**O índice parcial funcionou como projetado e ainda assim o ganho foi nulo.**
Isso está na tabela porque medir e descartar é mais forte do que só mostrar o
que deu certo.

O que o plano mostra (`q2_after.txt`):

- `idx_recon_divergent` **é usado** — `Parallel Index Scan using
  ..._idx_recon_divergent` em todos os chunks de `reconciliation_events`.
- `idx_accounts_id_covering` **é usado e vira Index Only Scan** — o `INCLUDE`
  eliminou o heap fetch nas 17.859 buscas por conta de origem e destino.
- Mesmo assim: 1.584 ms → 1.511 ms.

**Por que não adiantou:** o gargalo de Q2 não está em `reconciliation_events`
(114.953 linhas divergentes) nem em `accounts`. Está no join com
`transactions`, que continua fazendo `Parallel Seq Scan` sobre os chunks da
janela de 30 dias — ~830 mil linhas. Acelerar o lado pequeno de um join não
muda o custo do lado grande.

**Conclusão prática:** para Q2 valer a pena, o próximo passo não é outro
índice em `reconciliation_events`, é reduzir o lado de `transactions` —
seja restringindo mais a janela, seja materializando o join. Um índice a mais
aqui só custaria escrita e espaço.

## Seletividade do índice parcial

`idx_recon_divergent` cobre `WHERE abs(difference) > 0.01`: **114.953 de
1.442.266 linhas = 7,97%**. É a premissa de seletividade que S06 assume
(~8%) — um índice parcial que cobrisse a maioria das linhas não teria
vantagem sobre um índice comum.

> Nota de honestidade sobre o dado: a primeira versão do gerador produzia
> divergência como percentual do valor (`amount * 0.2%`), o que fazia **86%**
> das reconciliações divergirem — toda TED de R$ 100 mil divergia em R$ 100 e
> o filtro `> 0,01` não filtrava nada. Também gravava `reconciled_at = now()`
> para todas as linhas, então "últimos 30 dias" incluía 100% da tabela.
> Ambos corrigidos na etapa 07 (divergência absoluta em centavos, aplicada a
> ~8% das linhas; `reconciled_at` derivado de `created_at` + atraso de até
> 8h), e as medições de Q2 foram **refeitas do zero** — before e after — sobre
> o dado corrigido. Os números de Q2 nesta tabela são todos pós-correção.

## Q4 — o que a window function realmente ganha

2.814 ms → 1.274 ms (2,2×), mas o número esconde o ponto principal:

- **Self-join**: `Parallel Hash Join` com `Rows Removed by Join Filter:
  319.645` — o plano constrói o produto de combinações e depois descarta quase
  tudo. Cresce quadraticamente com a janela.
- **Window function**: uma passada com `LAG()` sobre partição lógica. Cresce
  linearmente.

Na janela de 7 dias (~959 mil linhas) a diferença é 2,2×. Em 90 dias o
self-join fica inviável e a window function continua linear — é aí que a
escolha importa, não nesta escala.

**Limitação declarada:** ambas as versões retornam **0 linhas** neste dataset.
Duplicata exige coincidência exata de `amount` + conta de origem + conta de
destino em 5 minutos; com `amount` log-normal contínuo e 500 mil contas, a
probabilidade é desprezível. As duas queries medem honestamente o custo de
*procurar* duplicatas — que é o que se mede em produção na maior parte do
tempo — mas não o custo de *retorná-las*.

## Compressão — 5,0× no total, 23,5× na tabela

Medido com `hypertable_compression_stats('transactions')` após a política de
7 dias comprimir os 330 chunks elegíveis (de 338 no total; os 8 mais recentes
estão dentro da janela e seguem descomprimidos, por design).

| | Antes | Depois | Taxa |
|---|---|---|---|
| **Total da hypertable** | 2.674 MB | 536 MB | **5,0×** |
| Só os dados da tabela | 1.188 MB | 51 MB | **23,5×** |
| Só os índices | 1.484 MB | 5,3 MB | 287× |

**A taxa total ficou abaixo da expectativa de 10–20× de S03, e o motivo é
interessante o bastante para estar aqui.** A compressão da *tabela* entregou
23,5×, acima do previsto. O que puxa o número para baixo é que este dataset
carrega **1.484 MB de índice para 1.188 MB de dado** — os 4 índices criados na
etapa 07 pesam mais que a própria tabela. A expectativa de S03 assume a razão
tabela/índice de uma hypertable sem os índices de otimização que a etapa 07
acrescentou de propósito.

Ou seja: as duas otimizações do desafio se pagam uma contra a outra. Índice
acelera query pontual e custa espaço; compressão devolve espaço. A leitura
correta do 5,0× não é "a compressão decepcionou" — é "o custo de espaço dos
índices é real e mensurável, e aparece justamente quando se comprime".

`segmentby = 'source_institution, type'` — 15 × 4 = 60 combinações, todas de
cardinalidade baixa, e são as colunas do filtro da maioria das queries: um
`WHERE source_institution='001'` descomprime só os segmentos daquela
instituição. `orderby = 'created_at DESC, status'` explora o fato de o dado já
chegar nessa ordem, o que faz o delta-encoding render.

## Retenção — a política que existe e fica desligada

O enunciado pede 12 meses de dado **e** retenção de 90 dias. As duas coisas
não coexistem: aplicar a política literalmente apagaria 9 dos 12 meses.

A saída foi criar a política — ela é a política correta para produção — e
deixá-la `scheduled = false`. `make demo-retention`
(`desafio-1/scripts/retention-demo.sh`) prova que ela funciona sem destruir
nada: insere linhas sintéticas em 2020 (intervalo onde o dataset real não tem
nada), calibra `drop_after` para que o limite caia em 2021, roda o job pelo
mecanismo real do TimescaleDB (`CALL run_job`), mostra os 3 chunks sintéticos
sendo removidos e restaura o estado. Ao final: **10.000.000 linhas, política
de volta a 90 dias e desligada.**

Assimetria deliberada: a retenção de **2 anos sobre os 2 CAggs fica ligada**.
O dataset tem 12 meses, então 2 anos não alcança nada — é a política certa e
inofensiva. Só a do raw conflita, e só ela fica parada.

| Política | Janela | `scheduled` |
|---|---|---|
| `transactions` (raw) | 90 dias | **false** — conflita com o dataset de 12 meses |
| `cagg_volume_hourly` | 2 anos | true |
| `cagg_settlement_latency_daily` | 2 anos | true |

**O comando que habilita**, quando o conflito não existir (produção real, onde
os 90 dias são a política desejada):

```sql
-- job_id 1007 é a retenção do raw; os outros dois (1004, 1005) já estão ligados.
SELECT alter_job(1007, scheduled => true);

-- Conferir:
SELECT job_id, proc_name, hypertable_name, scheduled, schedule_interval
  FROM timescaledb_information.jobs WHERE job_id >= 1000 ORDER BY job_id;
```

A partir daí o job roda no intervalo agendado e remove chunks inteiramente
anteriores a `now() - 90 dias`. **Não é reversível** — por isso fica desligada
enquanto o dataset de 12 meses for o objeto da avaliação.

## Limitação declarada — P95/P99 sem o toolkit

S03 especifica `percentile_agg` (TDigest) para o CAgg de latência. **A
extensão `timescaledb_toolkit` não existe na imagem fixada
`timescale/timescaledb:latest-pg16`** — verificado: ausente de
`pg_available_extensions` e sem binários no container. Ela vem nas imagens
`-ha`, e trocar a imagem violaria a reprodutibilidade que o projeto assumiu
como requisito.

Adotamos o plano B previsto pelo próprio S03:

- O **CAgg materializa o que é somável** — contagens, `sum(latência)`,
  `sum(latência²)`, min e max. Essas colunas rollupam de dia para mês sem
  reprocessar o bruto, e a média sai exata de `sum/count`.
- O **P95/P99 sai de `percentile_cont`** na view `v_settlement_latency_percentiles`,
  sobre o raw filtrado.

**O requisito do PDF § 3.2 A.4b é P95 *e* P99 de latência de liquidação por
instituição — e é isso que a view entrega**, na granularidade dia × instituição:

```sql
SELECT bucket::date, source_institution, settled_count,
       round(p95_seconds::numeric, 1) AS p95,
       round(p99_seconds::numeric, 1) AS p99
  FROM v_settlement_latency_percentiles
 WHERE bucket >= now() - INTERVAL '3 days'
 ORDER BY bucket DESC, source_institution;
```

Saída real (2026-08-04, segundos):

| dia | instituição | liquidadas | P95 | P99 |
|---|---|---|---|---|
| 2026-08-04 | 001 | 246.488 | 55.101,4 | 114.519,8 |
| 2026-08-04 | 033 | 42.029 | 56.627,2 | 114.910,8 |
| 2026-08-04 | 077 | 28.849 | 55.698,9 | 118.384,2 |
| 2026-08-04 | 104 | 53.564 | 54.075,5 | 114.837,3 |

Os valores altos (P95 ≈ 15h) são propriedade do **dataset sintético**, não da
consulta: o gerador distribui `settled_at` ao longo de dias, não de segundos.
A forma da métrica é a que o requisito pede; a magnitude reflete o dado que
existe.

**O que se perde:** os percentis não vêm pré-computados, então essa query
ainda toca a hypertable. **Por que não dá para materializar mesmo assim:**
percentil **não é somável**. Não se tira o P95 do dia a partir dos P95 de cada
hora — a função não é associativa, e o erro seria silencioso. `percentile_cont`
é exata mas exige todas as linhas ordenadas em memória, e é exatamente por
isso que ela não pode viver num continuous aggregate: não há resultado parcial
que se combine. `percentile_agg` resolveria trocando exatidão por
combinabilidade (erro tipicamente < 1%); sem o toolkit, a escolha honesta é
manter a exatidão e pagar a varredura.

### A armadilha do `failed_count` neste CAgg

`cagg_settlement_latency_daily` filtra `WHERE settled_at IS NOT NULL`, e
**nenhuma transação `failed` tem `settled_at`** (verificado: 0 de 35.028 na
última semana). Logo `failed_count` é sempre 0 e `total_count` é, na verdade,
"total liquidado" — não "total emitido". Uma taxa de falha calculada daqui
devolveria `0,0000` para toda instituição: um zero que parece métrica e é só
o filtro se olhando no espelho.

As colunas foram mantidas porque o schema é contrato de S03, mas ambas levam
comentário de aviso no DDL, e a Q3 via CAgg **não** calcula taxa de falha —
essa vem do `cagg_volume_hourly`, que agrega por `status` sem filtrar nada.

## ClickHouse — backfill e query sub-segundo (etapa 12)

Backfill direto PostgreSQL→ClickHouse via `postgresql()` table function, em
12 blocos mensais (S05 § Backfill inicial), sem passar pelo Kafka —
`scripts/backfill-clickhouse.sh`, 56s no total.

| Verificação | Resultado |
|---|---|
| `count(*)` em `transactions_raw` | 10.000.000 (bate com a origem) |
| `count() FINAL` (dedup) | 10.000.000 — sem duplicata introduzida pelo backfill |
| Contagem por mês (12 blocos) CH vs PG | idêntica nos 12 meses |
| `countMerge` total em `daily_by_institution` | 10.000.000 |
| `countMerge` total em `status_funnel` | 10.000.000 |

### A armadilha real: MV já ativa duplica o backfill

As 2 MVs (criadas na etapa 11) são **gatilho de inserção**, não view — e já
estavam ativas quando o backfill do raw rodou. Elas capturaram sozinhas cada
um dos 12 blocos mensais inseridos em `transactions_raw`. Rodar o
`INSERT SELECT` de backfill das MVs *depois* disso (como S04 descreve para o
cenário "MV criada depois do dado já carregado") duplicou tudo: **20.000.000
agregados em vez de 10.000.000**, verificado com `countMerge` agrupado.

Corrigido truncando as 2 tabelas de agregação e rodando o `INSERT SELECT`
uma única vez, sem novo `INSERT` em `transactions_raw` no meio — aí sim os
20M viraram 10M exatos. `scripts/backfill-clickhouse.sh` agora checa se a
tabela de agregação já tem linhas antes de rodar o `INSERT SELECT`, para não
reproduzir o erro numa reexecução.

**A lição, além do número:** "MV é gatilho, backfill posterior é obrigatório"
(S04) é meia verdade sem o contexto de *quando* a MV foi criada em relação
ao backfill do raw. Aqui a ordem real (schema com MV ativa → backfill do raw)
é diferente do cenário canônico que S04 descreve (dado já carregado → MV
criada depois) — e a mesma frase de aviso vira armadilha inversa se aplicada
sem atenção à ordem real dos eventos.

### Query do Grafana em sub-segundo — Pix 24h vs D-1

Requisito do PDF: taxa de sucesso de Pix por instituição por hora nas
últimas 24h, comparada ao mesmo horário do dia anterior, sub-segundo mesmo
com centenas de milhões de registros.

Protocolo de S04 § Como medimos: `SET log_queries=1`, `SYSTEM FLUSH LOGS`,
mediana de 3 execuções (1ª descartada) via `system.query_log`.

| Execução | `query_duration_ms` | `read_rows` |
|---|---|---|
| 1 (descartada) | 10 | 5.882 |
| 2 | 7 | 5.882 |
| 3 | 7 | 5.882 |
| 4 | 46 | 5.882 |

**Mediana: 7 ms** — muito abaixo do alvo de <1000ms. `read_rows` = 5.882 em
todas as execuções (a MV agregada, não os 10M da raw).

Os 4 fatores que entregam o sub-segundo (comentados em
`desafio-1/queries/grafana_pix_24h_vs_d1.sql`): lê de `status_funnel`
(MV agregada, dezenas de milhares de linhas) em vez da raw; uma passada
para os dois períodos (48h com classificação por `if()`, não 2 SELECTs);
`type='pix'` é a 1ª coluna do `ORDER BY` de `status_funnel` — índice esparso
corta a maior parte do dado logo no início; filtro de 48h toca no máximo
2 partições mensais.

**Correção real sobre a query ilustrativa de S04:** o SQL de referência usa
`countIfMerge(cnt)` assumindo que `cnt` já veio de um `countIfState`
filtrado por sucesso. Na nossa `status_funnel`, `status` é coluna do
`GROUP BY` (uma linha por hora/instituição/status), e `cnt` foi gravado com
`countState()` puro — `countIfMerge` sobre um estado sem filtro embutido dá
`ILLEGAL_TYPE_OF_ARGUMENT`. A query real deriva "sucesso" filtrando
`status='settled'` na leitura (`sumIf` sobre o valor já desagregado por
`countMerge`), não na agregação. Erro pego rodando a query de verdade, não
copiando o SQL de S04 sem testar.

## Dictionary vs JOIN — quando usar cada um (PDF § 3.2 C.3)

`dict_institutions` resolve o código da instituição (`'001'`) para o nome
(`'Instituição Parceira 1'`) sem trazer a tabela do legado para o caminho
quente. A alternativa seria uma `JOIN` contra o PostgreSQL a cada consulta.

**Medido nos dois caminhos**, mediana de 3 execuções (1ª descartada), mesmo
dado e mesma resposta:

| Padrão de uso | `dictGet` | `JOIN postgresql()` | Diferença |
|---|---|---|---|
| **Lookup por linha** (10.000 linhas, 90 dias) | **4 ms** | 15 ms | **3,75×** |
| `GROUP BY` sobre 10M linhas | **11 ms** | 147 ms | **13,4×** |
| `GROUP BY` com filtro de 90 dias | **18 ms** | 72 ms | **4,0×** |

**O número que importa é o primeiro**, porque é o padrão da API: resolver o
nome em cada linha do resultado. É onde o Dictionary foi posto para trabalhar
(`/institutions/{code}/health`).

> **Estes números substituem uma medição anterior (2,9× / empate / empate) que
> estava sistematicamente subestimada.** A medição da etapa 16 rodou contra um
> Dictionary que resolvia apenas **33,55%** das linhas — os códigos do seed do
> legado (`001`–`015`) não batiam com os das transações (`237`, `341`, `104`…),
> e só o `001` coincidia. Um lookup que devolve o *default* sai pelo caminho
> curto e **não paga o custo real da resolução**, então o `dictGet` parecia mais
> lento do que é e a JOIN — que também não achava nada — parecia competitiva.
> Corrigido o seed (etapa 17.5), a resolução foi a **100%** e os três padrões
> passaram a favorecer o Dictionary. A lição vale além deste número: **medir
> sobre dado que não casa mede o caminho de erro, não o caminho de uso.**

**Por que o `GROUP BY` sobre 10M é o maior ganho (13,4×).** É onde a JOIN mais
sofre: ela vai ao PostgreSQL e materializa o lado direito a cada execução,
enquanto o Dictionary já está em memória (15 linhas, **42,91 KiB** em
`system.dictionaries`). Com a resolução em 34%, esse custo ficava mascarado
porque a maioria das linhas nem chegava a resolver.

**Quando preferir Dictionary:**

| Critério | Por quê |
|---|---|
| Lookup por linha em consulta quente | 3,75× medido; a diferença cresce com o número de linhas resolvidas |
| Dado de referência pequeno e estável | 15 linhas em **42,91 KiB** de RAM (`system.dictionaries`) — cabe em memória sem negociação |
| Origem externa que não deve ser consultada a cada query | O `LIFETIME(240–360s)` amortiza; a JOIN vai ao PostgreSQL **toda vez** |
| Resposta precisa sobreviver à origem fora do ar | O Dictionary serve da memória; a JOIN falha |

**Quando preferir JOIN:**

| Critério | Por quê |
|---|---|
| Tabela grande demais para a memória | `HASHED` carrega tudo; centenas de MB por réplica deixam de compensar |
| Consistência transacional estrita | O Dictionary é sempre até `LIFETIME` segundos velho; a JOIN lê o estado atual |
| Uso raro, fora do caminho quente | Não paga a complexidade de manter um Dictionary |
| Junção por múltiplas colunas com predicados | É JOIN relacional de verdade, não lookup chave→valor |

**O custo que o Dictionary cobra** e que o número de latência não mostra:
memória residente por réplica, mais uma peça a operar (recarga, frescor,
alerta próprio — `refsync_dictionary_age_seconds`), e **dado que pode estar
até 6 minutos velho**. Para cadastro de instituição, que muda em escala de
semanas, é irrelevante. Para saldo ou limite, seria inaceitável — aí a JOIN
é a resposta certa.

## Funil de status — mede estado, não transição (limitação declarada)

O PDF § 3.2 C.2b pede um funil de status **com tempo médio em cada estágio**.
A MV `status_funnel` entrega a contagem e o tempo por status, mas é preciso
ser explícito sobre o que ela **não** mede:

**A origem não guarda histórico de transições.** `transactions` tem uma coluna
`status` que é **sobrescrita** a cada mudança (`pending` → `settled`), e um
único `updated_at`. Não existe tabela de eventos de mudança de estado, nem
`status_history`, nem log de transição.

Consequência direta:

| O que o funil mede | O que ele **não** mede |
|---|---|
| Quantas transações estão **hoje** em cada status | Quantas **passaram** por cada status |
| `settled_at - created_at` para as liquidadas | Quanto tempo ficaram em `pending` antes de falhar |
| Distribuição do estado final | O caminho percorrido até ele |

Uma transação que foi `pending` → `failed` → (reprocessada) → `settled`
aparece no funil **apenas como `settled`**. Os dois estágios intermediários
não deixaram rastro na origem, então nenhuma modelagem no destino os recupera.

**Por que não foi "corrigido":** capturar transição exigiria mudar o schema da
origem — tabela de eventos de status, ou `DELETE`+`INSERT` versionado em vez
de `UPDATE`. É mudança no sistema transacional de pagamentos, decidida por
quem opera aquele sistema, não pela camada analítica. O que a análise pode
fazer é **declarar a limitação em vez de deixar o leitor supor** que o funil
mede jornada quando ele mede fotografia.

**O que seria necessário para medir de verdade**, se o requisito se tornar
firme: uma tabela `transaction_status_events` (append-only) na origem, com
`(tx_id, status_anterior, status_novo, mudou_em)`. A partir dela, o tempo em
cada estágio sai de `lead(mudou_em) - mudou_em`, e o funil vira jornada real.
O pipeline atual capturaria essa tabela sem alteração de desenho — é a origem
que precisa mudar, não o destino.

## Limitação declarada: `accounts` não vai ao ClickHouse (e o que isso custa)

A tabela `accounts` é a única com PII e **nunca é replicada para o ClickHouse**,
por desenho de S01. `transactions_raw` referencia o titular apenas por
`source_account_id` (inteiro). Verificado por varredura de `system.columns` na
etapa 16: **zero colunas de dado pessoal** no motor analítico.

O ganho é direto — LGPD, superfície de auditoria e o procedimento de eliminação
ficam contidos num único banco. **O custo, que vale declarar antes que
perguntem:** perguntas que cruzam transação com dado de conta — a classe da
**Q2 (reconciliação)** — só são respondíveis no TimescaleDB. Um Data Champion
que trabalhe apenas no ClickHouse **não consegue respondê-las ali**.

| Caminho | Quando |
|---|---|
| API / MVs no ClickHouse | Todo o resto — volume, latência, funil, série histórica |
| TimescaleDB com perfil restrito e acesso nominal | Só quando a pergunta exige dado de conta |

É trade-off assumido, não omissão: trocamos uma classe de pergunta menos
frequente por um motor analítico livre de dado pessoal. Documentado para o
consumidor final em [`docs/DATA-CHAMPIONS.md`](../docs/DATA-CHAMPIONS.md) § 6.

## Ambiente

`shm_size: 1gb` no serviço `timescaledb` (default do Docker é 64 MB): sem
essa folga o hash join de Q4 falha com `could not resize shared memory
segment` antes de produzir plano. Índices criados via `make indexes` **após**
a carga — criar índice durante `COPY` de 10M é ordens de magnitude mais lento.
