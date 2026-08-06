# Custo estimado em AWS — TCO da plataforma

[← Voltar ao README](../README.md)

> **Estimativa, não cotação.** Preços de tabela pública `us-east-1`
> (Norte da Virgínia), consultados em **agosto de 2026**, sem Savings Plans,
> Reserved Instances ou desconto de contrato. Preço muda; número sem data
> envelhece mal, por isso a data está no topo e não em rodapé.
>
> Cada linha traz **a premissa de dimensionamento que gerou o número**. É a
> premissa que se discute numa aprovação de orçamento — o valor é consequência
> dela. Onde a premissa estiver errada, o número corrige junto.

---

## Os dois cenários

| | Cenário A — atual | Cenário B — 10× |
|---|---|---|
| Transações/mês | 10.000.000 | 100.000.000 |
| Escrita sustentada | ~4 tx/s (pico ~580) | ~38 tx/s (pico ~5.800) |
| Dado quente (TimescaleDB, 90d) | ~536 MB comprimido (5,0× medido) | ~5,4 GB comprimido |
| Dado analítico (ClickHouse, 12m) | ~2 GB | ~20 GB |
| Data Champions ativos | 5–10 | 20–30 |

O volume do cenário A é o que está carregado e medido neste repositório. O
cenário B é o "e se triplicasse/decuplicasse" do PDF § 7, dimensionado pelos
4 movimentos de escala do `desafio-2/ADR.md`.

---

## Cenário A — 10M transações/mês

| Serviço | Dimensionamento assumido | USD/mês |
|---|---|---|
| **Aurora PostgreSQL** (transacional) | Serverless v2, 2–8 ACU, média 3 ACU × 730 h × $0,12/ACU-h | **263** |
| Aurora — storage | 60 GB × $0,10/GB | 6 |
| Aurora — I/O | ~50M requests × $0,20/milhão | 10 |
| **Aurora PostgreSQL** (legado) | Serverless v2, 0,5–2 ACU, média 0,5 ACU (86 MB, quase ocioso) | **44** |
| **ClickHouse em EC2** | 1× `m6i.2xlarge` (8 vCPU/32 GB) on-demand, 730 h × $0,384 | **280** |
| ClickHouse — EBS gp3 | 200 GB × $0,08/GB + baseline IOPS | 16 |
| **ECS Fargate** (api, sync-worker, ref-sync) | 3 tasks × 0,5 vCPU × 1 GB × 730 h | **44** |
| **S3** (backup pgBackRest + ClickHouse) | 150 GB Standard + lifecycle p/ IA aos 30d; PUT/GET do WAL contínuo | **6** |
| **CloudWatch** | Logs 20 GB/mês + 30 métricas custom + 10 alarmes | **18** |
| **Managed Grafana** | 3 editores × $9 + 10 viewers × $5 | **77** |
| **Secrets Manager** | 6 segredos × $0,40 + chamadas de API | **3** |
| **PrivateLink** (acesso do Hex) | 1 endpoint × 2 AZ × 730 h × $0,01 + dados | **17** |
| **NAT Gateway** | 1× (subnets privadas precisam de saída) × 730 h + ~50 GB | **37** |
| **ALB** | 1 × 730 h + LCUs baixos | **20** |
| **KMS** | 2 CMKs × $1 + requests | **3** |
| | **Total cenário A** | **≈ 844** |

### Base de comparação — o que já se paga hoje

| Alternativa gerenciada | Dimensionamento | USD/mês |
|---|---|---|
| **Timescale Cloud** (substituindo o Aurora transacional) | 4 vCPU / 16 GB, 100 GB storage, HA réplica | ≈ 400–500 |
| **ClickHouse Cloud** (substituindo o EC2) | Development → Production, ~8 vCPU, 200 GB | ≈ 350–600 |

Somando os dois gerenciados no lugar dos dois autogeridos: **≈ 750–1.100/mês**
contra os ≈ 844 da tabela acima. A conclusão honesta é que **não há economia
relevante em operar por conta própria neste volume** — o custo de infra é
praticamente o mesmo, e o gerenciado devolve horas de operação. A decisão de
autogerir só se paga a partir do cenário B, onde o preço por vCPU do gerenciado
escala mais rápido que o do EC2 reservado.

> Esse é o número que responde "quanto o Timescale Cloud já consome": no
> dimensionamento equivalente ao dado carregado aqui, **$400–500/mês**. Sem essa
> âncora, a tabela de TCO flutua e não sustenta comparação.

---

## Cenário B — 100M transações/mês (10×)

| Serviço | O que muda no dimensionamento | USD/mês |
|---|---|---|
| **Aurora PostgreSQL** (transacional) | 4–16 ACU, média 8 ACU; + 1 réplica de leitura | **700** |
| Aurora — storage + I/O | 400 GB + ~500M requests | 140 |
| **Aurora PostgreSQL** (legado) | Inalterado — o legado não escala com transação | **44** |
| **ClickHouse em EC2** | 2× `m6i.4xlarge` (shard por faixa de instituição, movimento 1 do ADR) | **1.120** |
| ClickHouse — EBS gp3 | 1 TB + IOPS provisionado | 100 |
| **ECS Fargate** | api 2→6 tasks (autoscaling); sync-worker 1→4 workers particionados | **160** |
| **S3** | 1,2 TB com lifecycle Standard→IA→Glacier IR | **28** |
| **CloudWatch** | Logs 150 GB + métricas por worker | **95** |
| **Managed Grafana** | 5 editores + 30 viewers | **195** |
| **Secrets Manager / KMS / ALB / PrivateLink / NAT** | Escalam pouco com volume; NAT sobe com transferência | **95** |
| | **Subtotal sem fila** | **≈ 2.677** |
| **MSK** *(se acionado — ver abaixo)* | 3 brokers `kafka.m5.large`, 3 AZ, 1 TB storage | **+ 620** |
| | **Total cenário B, com fila** | **≈ 3.297** |

**Custo por milhão de transações**: cenário A ≈ **$84**; cenário B ≈ **$27**
(sem MSK) ou **$33** (com MSK). A economia de escala vem das MVs — elas agregam
na ingestão, então o custo de consulta cresce com o que entra, não com o
acumulado (`ADR.md`, movimento 3).

---

## O MSK que foi adiado — custo evitado

O `ADR.md` põe a fila como **último** dos 4 movimentos de escala, e o motivo
escrito lá é operacional ("fila é a peça que mais custa a operar"). O número
fecha o argumento:

| | USD/mês |
|---|---|
| MSK — 3 brokers `kafka.m5.large` (3 AZ), 1 TB storage | 620 |
| MSK Serverless — alternativa, ~40 MB/s sustentado | ~480 |
| **Micro-batch por watermark (a decisão tomada)** | **0** — roda dentro da task Fargate já contabilizada |

**Custo evitado: ≈ $620/mês, ou ~$7.400/ano**, mantido enquanto o micro-batch
absorver a carga. No cenário A isso é **73% do custo total da plataforma** — a
fila custaria quase tanto quanto todo o resto junto.

Não é economia gratuita: sem fila, um pico que exceda a janela do micro-batch
vira lag, não buffer. O gatilho de reversão está no ADR (movimento 4), e o
teste de saturação é o que dirá em qual patamar ele arma.

---

## Aurora vs RDS — a diferença em dólar

Detalhado em `desafio-1/migration-analysis.md`. Resumo:

| | Cenário A | Cenário B |
|---|---|---|
| **Aurora Serverless v2** (transacional) | $279 | $840 |
| **RDS `db.m6g.large` Multi-AZ** equivalente | $253 | $1.010 (precisa `db.m6g.2xlarge`) |
| Diferença | **+$26 (+10%)** | **−$170 (−17%)** |

A inversão é o ponto: no cenário A o Aurora custa **mais** — o "20–30% acima do
RDS" da versão anterior deste documento era verdade só por vCPU, e não sobrevive
quando se conta o Serverless v2 escalando para baixo em horário ocioso. No
cenário B o Aurora custa **menos**, porque o RDS precisa provisionar para o pico
24/7 enquanto o Aurora acompanha a carga.

**Consequência para a decisão**: a recomendação de Aurora no
`migration-analysis.md` se sustenta por HA e reader endpoint, **não por preço**
no volume atual. Vender Aurora como economia hoje seria falso; a economia chega
com o crescimento.

---

## O que este documento não cobre

| Não estimado | Por quê |
|---|---|
| Transferência de dados entre regiões | Arquitetura é single-region; multi-region é outra decisão, com outro custo |
| Ambientes de dev/homologação | Regra prática: +40–60% sobre produção, dependendo se dev fica ligado fora do horário |
| Suporte AWS (Business ≈ 10% da conta) | Decisão comercial, não de arquitetura — em A seriam ≈ $84/mês |
| Custo de pessoas | O maior item real de TCO e o mais fora do escopo deste desafio |
| Hex | Licença SaaS de terceiro; o custo AWS associado é só o PrivateLink já contabilizado |

---

## Como refazer estes números

As premissas estão em cada linha justamente para serem recalculadas. O que mais
move o total, em ordem:

1. **Classe da instância do ClickHouse** — 33% do cenário A. Ajustar depois do
   teste de saturação, que dirá se `m6i.2xlarge` é folgado ou justo.
2. **ACU médio do Aurora** — Serverless v2 cobra pelo que usa; o valor médio só
   se conhece com uma semana de produção.
3. **Reserved Instances / Savings Plans** — 1 ano sem entrada corta ~30% do
   compute. Deliberadamente **fora** desta tabela: comprometer capacidade antes
   de medir o regime real é como se erra dimensionamento.
