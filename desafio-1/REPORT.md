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
| Q1 — volume/valor por tipo+status, 6 meses | 12.115 ms | (etapa 08) | — | CAgg | hit=95.670 → — |
| Q2 — divergências de reconciliação, 30 dias | 1.584 ms | 1.511 ms | **~1,05× (dentro do ruído)** | Índice parcial + covering `INCLUDE` | hit=157.938 read=170.126 → hit=124.389 read=167.109 |
| Q3 — top 20 instituições, 90 dias | 1.285 ms | 394 ms | **3,3×** | Índice covering `INCLUDE` | hit=53.407 read=0 → hit=23.317 read=0 |
| Q4 — duplicatas 5 min | 2.814 ms | 1.274 ms | **2,2×** | Self-join → window function `LAG()` | hit=31.712 read=150.693 → hit=15.792 temp=7.758 |
| Gapfill 48h | n/a | 49 buckets, 0 nulos | n/a | `time_bucket_gapfill` + `locf`/`interpolate` | — |

Q1 aparece sem "depois" de propósito: sua otimização é ler do continuous
aggregate, que é criado na etapa 08. Índice não resolve Q1 — a lição é que a
melhor otimização de uma agregação frequente não é acelerar a leitura do dado
bruto, é não percorrer o dado bruto.

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

## Ambiente

`shm_size: 1gb` no serviço `timescaledb` (default do Docker é 64 MB): sem
essa folga o hash join de Q4 falha com `could not resize shared memory
segment` antes de produzir plano. Índices criados via `make indexes` **após**
a carga — criar índice durante `COPY` de 10M é ordens de magnitude mais lento.
