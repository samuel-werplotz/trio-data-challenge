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

## Ambiente

`shm_size: 1gb` no serviço `timescaledb` (default do Docker é 64 MB): sem
essa folga o hash join de Q4 falha com `could not resize shared memory
segment` antes de produzir plano. Índices criados via `make indexes` **após**
a carga — criar índice durante `COPY` de 10M é ordens de magnitude mais lento.
