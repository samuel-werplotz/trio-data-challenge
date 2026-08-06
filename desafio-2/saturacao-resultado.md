# Teste de saturacao do pipeline — resultado

[← Voltar ao README](../README.md)

Gerado por `scripts/saturacao-pipeline.sh` em 2026-08-05 01:39 UTC.
Ambiente: Docker local (ver `scripts/ambiente/DOCKER-LOCAL.md`), nao AWS.

| Patamar alvo | Linhas | Tempo de escrita | Taxa real (linhas/s) | Lag apos (s) | Freshness (s) | Entregues | Erros |
|---|---|---|---|---|---|---|---|
| 500/s | 500 | 0.38s | 1316 | 3.4 | 32 | 500/500 ✅ | 0 |
| 1000/s | 1000 | 0.36s | 2778 | 7.1 | 28 | 1500/1500 ✅ | 0 |
| 3000/s | 3000 | 0.40s | 7500 | 1.1 | 34 | 4500/4500 ✅ | 0 |
| 5800/s | 5800 | 0.47s | 12340 | 4.9 | 30 | 10300/10300 ✅ | 0 |
| 60000/s | 60000 | 1.08s | 55556 | 19.2 | 41 | 70300/70300 ✅ | 0 |

## Integridade

| | Linhas sinteticas |
|---|---|
| Origem (TimescaleDB) | 70300 |
| Destino (ClickHouse) | 70300 |

**Nenhuma perda**: o pipeline entregou 100% do que foi escrito.

## Leitura dos números

**O pipeline não saturou em nenhum patamar** — e o dado mais importante desta
tabela é o que ela *não* mostra: nenhum ponto de quebra por vazão.

| Observação | Número | Consequência |
|---|---|---|
| Escrita na origem é sempre mais rápida que o ciclo | 60.000 linhas em **1,08 s** | O gargalo nunca é a ingestão do TimescaleDB |
| Lag máximo, no maior patamar | **19,2 s** | Abaixo do alvo de 30 s do ADR, com folga |
| Freshness no pior caso | **41 s** | Acima do alvo, e é o número honesto: o lote de 60.000 exige 2 ciclos |
| Perda | **zero em 70.300 linhas** | Conferido patamar a patamar, não só no total |
| Erros | **0** | Nenhum retry, nenhuma DLQ |

**Onde está o limite real, então.** Não é vazão — é o **tamanho do lote em um
único `updated_at`**. Enquanto uma rajada couber em `BATCH_MAX_ROWS` (50.000), o
ciclo drena em uma passada; acima disso, são dois ciclos, e o lag sobe
proporcionalmente. É configuração, não arquitetura: `BATCH_MAX_ROWS` maior troca
lag por memória por ciclo.

> **Este teste existe porque a versão anterior dele mentia por omissão.** Os
> quatro primeiros patamares (500 → 5.800/s) passavam com folga e teriam
> sustentado a conclusão "o pipeline aguenta o pico de 5.800/s do cenário 10×".
> Verdadeiro e inútil: `INSERT` em massa escreve 5.800 linhas em 0,47 s, e
> nenhum desses patamares chega perto do lote. Só o de **60.000** — o único
> acima de `BATCH_MAX_ROWS` — exercitou a retomada dentro de um mesmo
> `updated_at`, e foi ele que revelou o deadlock de watermark corrigido na
> **este teste** (10.000 de 60.000 linhas perdidas em silêncio).

## O que este teste não mede

| Não medido | Por quê |
|---|---|
| Carga **sustentada** por minutos | Cada patamar é uma rajada seguida de drenagem. Um fluxo contínuo a 5.800/s por 10 min exercitaria merge e acúmulo de parts, que aqui nem aparecem |
| Concorrência de leitura durante a escrita | Ninguém consultava o ClickHouse durante o teste |
| Comportamento com 2+ workers particionados | O movimento 1 de escala do ADR não foi exercitado |
| Recursos (CPU/memória) por patamar | `docker stats` não foi amostrado; o worker nunca passou de 1 s de ciclo |

Os quatro são trabalho de um teste de carga de produção, não de um desafio em
Docker local — mas a ausência está declarada em vez de subentendida.
