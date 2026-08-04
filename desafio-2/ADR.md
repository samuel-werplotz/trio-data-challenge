# ADR — Pipeline analítico de transações: TimescaleDB → ClickHouse

**Status:** Aceito · **Data:** 2026-08-04 · **Escopo:** Desafio 2, Partes B e C

> Este ADR responde as quatro perguntas do PDF § 4.2 C.2 (uma por seção `##`) e
> descreve **o que de fato foi construído e medido**, não o desenho original. A
> divergência mais relevante: o CDC via Debezium foi construído, medido e
> **descartado por impossibilidade técnica provada** — a seção "Contexto" abre
> com isso porque é ela que explica todas as decisões seguintes.

---

## Contexto

Volume real carregado e medido neste repositório:

| Item | Número |
|---|---|
| `transactions` (TimescaleDB) | 10.000.000 linhas · hypertable 1d · 338 chunks |
| `transactions_raw` (ClickHouse) | 10.000.000 linhas · `count() FINAL` idêntico |
| Freshness do pipeline principal | ciclo de 10s, alvo < 30s |
| Query do painel (Pix 24h vs D-1) | mediana 7–8 ms (alvo < 1000 ms) |
| Q1 após índice + CAgg | 12.115 ms → 23 ms (**521×**) |

O problema é servir leitura analítica sobre dado transacional que muda o tempo
todo, sem que a carga analítica caia sobre o banco que processa pagamento.

### O que aconteceu com o CDC (e por que isso importa aqui)

O desenho original era Debezium (`pgoutput`) → Redpanda → consumidor Python.
Foi implementado por inteiro e **não funciona sobre hypertable**:

- `publish_via_partition_root = true` não tem efeito sobre chunk do TimescaleDB.
  Uma hypertable **não é tabela particionada nativa** do PostgreSQL: a mãe tem
  `relkind='r'` e o chunk tem `relispartition='f'`. Sem relação pai/filho
  declarada, o parâmetro não tem sobre o que agir e a escrita no chunk nunca
  entra na publication.
- Provado **isolando a decodificação lógica**, sem Debezium no circuito:

  | Teste | Resultado |
  |---|---|
  | `pg_logical_slot_peek_binary_changes` | **0 mudanças** |
  | `ALTER PUBLICATION … ADD TABLE <chunk>` e repetir | **6 mudanças na hora** |

  Ou seja: adicionar o chunk explicitamente resolve — mas seriam 338 tabelas
  rastreadas individualmente, crescendo um chunk por dia. Não é operável.

O pipeline entregue é **micro-batch por watermark** (`updated_at`), e ele não é
consolo: o PDF § 4.2 A.1 lista "pipeline custom com micro-batches" **em pé de
igualdade** com CDC entre as opções válidas, e cobra a justificativa escrita,
não a ferramenta. O experimento com Debezium está preservado no repositório sob
o profile `cdc-experimento` — a alternativa construída e medida vale mais como
resposta do que a alternativa descartada no papel.

---

## Por que não um ETL tradicional?

Porque o requisito é **freshness de segundos**, e ETL tradicional entrega
janelas de minutos a horas. As três razões concretas:

**1. Latência.** ETL clássico roda em janela agendada (horária, noturna) e
reprocessa a fatia inteira. O painel de operações da Trio precisa responder
"como está o Pix agora?" — com janela de 1h, "agora" tem até 60 minutos de
atraso. O sync-worker fecha o ciclo em **10 segundos**, com alvo de freshness
< 30s.

**2. Custo de reprocessar o que não mudou.** O `T` do ETL normalmente relê a
partição inteira para reescrevê-la. Aqui o watermark lê **só o que mudou desde
o último ciclo** (`updated_at >= watermark`), tipicamente alguns milhares de
linhas — não 10 milhões.

**3. O `T` já não é nosso.** A transformação pesada (agregação por instituição,
funil de status, percentis) acontece **dentro do ClickHouse**, em
`AggregatingMergeTree` + Materialized View, no momento da ingestão. Manter uma
camada de transformação externa seria duplicar o que o motor analítico já faz
melhor — foi o que permitiu a query do painel medir 7 ms lendo 5.882 linhas em
vez de 10 milhões.

**O que se perde, e é honesto declarar:** ETL tradicional tem ferramental maduro
de orquestração, lineage e retentativa por etapa. O micro-batch aqui é código
próprio — quem opera precisa entender o watermark, e não há UI de DAG para
inspecionar. A troca se paga nesta escala e com este requisito de latência; num
cenário de dezenas de fontes heterogêneas com dependências entre si, a conclusão
seria outra.

---

## Como escalar se o volume 10x?

10× significa **100 milhões de transações** e ~5.800 escritas/s de pico. O
desenho aguenta, em quatro movimentos, na ordem em que se aplicariam:

**1. Particionar a leitura (o passo que o desenho atual já habilita).** Hoje o
worker é um processo com um watermark. Para 10×, divide-se o espaço de chaves
por faixa de `source_institution` (ou hash de `id`), com **um watermark por
partição** — N workers independentes, sem coordenação entre si, porque cada um
tem sua própria janela. É escala horizontal linear e não exige mudar o schema.

**2. Aumentar o lote antes de aumentar a frequência.** `BATCH_MAX_ROWS` é 50.000
por ciclo. O ClickHouse prefere **poucos INSERTs grandes a muitos pequenos** —
cada INSERT vira uma *part* no disco, e parts demais forçam merges constantes
(`too many parts`). Subir o lote é mais barato que encurtar o ciclo.

**3. Deixar o trabalho pesado nas MVs.** Com 100M linhas, a diferença entre ler
a raw e ler o agregado deixa de ser conforto e vira viabilidade: a query do
painel lê 5.882 linhas da MV em vez de varrer a tabela. As MVs agregam **na
ingestão**, então o custo cresce com o que entra, não com o acumulado.

**4. Só então introduzir fila.** Se a origem passar a ter picos que o
micro-batch não absorve, entra **MSK (Kafka gerenciado)** entre origem e
destino, com o número de partições dimensionado pelo paralelismo desejado — o
consumidor já é idempotente (ver abaixo), então acrescentar fila não muda a
semântica de escrita. É deliberadamente o **último** passo: fila é a peça que
mais custa a operar, e os três anteriores resolvem sem ela.

**O que sustenta tudo isso é a idempotência.** `transactions_raw` é
`ReplacingMergeTree(_version)` com `_version = updated_at` em ms. Reprocessar a
mesma janela não duplica: a versão maior vence. Foi **testado** — reprocessar do
zero manteve `count() FINAL` idêntico. Sem essa propriedade, nenhum dos quatro
movimentos acima seria seguro.

### Limitação declarada: o funil de status mede estado, não transição

A MV `status_funnel` responde "quantas transações estão em cada status", não
"quantas passaram por cada status". **A origem não guarda histórico de
transições**: `transactions.status` é sobrescrito a cada mudança, e há um único
`updated_at`. Uma transação `pending` → `failed` → `settled` aparece no funil
só como `settled`.

Não é limitação do destino: capturar transição exige tabela de eventos na
**origem** (`transaction_status_events`, append-only), o que é mudança no
sistema transacional de pagamentos — decisão de quem opera aquele sistema. O
pipeline atual capturaria essa tabela sem alteração de desenho. Detalhado em
`desafio-1/REPORT.md` § *Funil de status*.

### Limitação declarada: o `DELETE`

O micro-batch por watermark **não captura `DELETE` físico**. Uma linha removida
com `DELETE FROM transactions` simplesmente deixa de aparecer no `SELECT` — não
há evento, e o watermark nunca "vê" a ausência. Consequências e mitigação:

- O schema já tem `_is_deleted`, então **exclusão lógica** (`UPDATE … SET
  deleted_at`) é capturada normalmente. É o padrão correto num domínio de
  pagamento, onde transação liquidada não se apaga — se estorna.
- Para `DELETE` físico (correção de incidente, expurgo LGPD), a reconciliação é
  a rede: comparar `count()` por período entre origem e destino e remover no
  ClickHouse a diferença. O procedimento de apagamento LGPD já é documentado
  como fluxo próprio, fora do pipeline incremental.
- O CDC capturaria `DELETE` nativamente. É a única capacidade real que se perde
  com a troca — e ela custa exatamente o que a seção Contexto mostrou ser
  impossível sobre hypertable.

---

## Onde entra o legado PostgreSQL/Aurora nessa evolução?

O legado entra como **fonte de dado de referência**, não de fato transacional —
e essa separação é a decisão, não um detalhe de implementação.

`partner_institutions` e `institution_configs` alimentam o `dict_institutions`
do ClickHouse, consumido com `dictGetOrDefault` no momento da leitura. É o que
transforma `source_institution = '001'` em `"Instituição Parceira 1"` na
resposta da API, sem join e sem trazer a tabela para o caminho quente.

**A sincronização é batch de 5 minutos, e deliberadamente não é CDC:**

| | Referência (`ref-sync`) | Transacional (`sync-worker`) |
|---|---|---|
| Frequência de mudança | semanas | milhares/segundo |
| Volume | ~200 linhas (15 hoje) | 10 milhões |
| Custo de 5 min de atraso | irrelevante | inaceitável |
| Complexidade se justifica? | **não** | sim |

Montar CDC para sincronizar 200 linhas que mudam por semana custaria um slot de
replicação lógica a mais num banco que é instância única, em troca de reduzir
uma latência que ninguém consome. **Saber quando não usar a ferramenta
sofisticada é parte da decisão.**

O `ref_sync.py` faz um papel estreito de propósito: o `LIFETIME(MIN 240 MAX 360)`
do Dictionary já recarrega sozinho: o worker encurta o tempo até a recarga
**quando a mudança de fato ocorre** (comparando `max(updated_at)` + `count(*)`,
par que detecta INSERT, UPDATE **e** DELETE) e publica
`refsync_dictionary_age_seconds`, a métrica de frescor que o `LIFETIME` não
expõe. Verificado em laço vivo: ciclos `unchanged`, `UPDATE` no legado no meio
do laço, ciclo seguinte `reloaded` com frescor de 1s.

### Migração para Aurora (PDF § 4.2 B.2)

**O pipeline sobreviveria sem alterações? Sim — e ganharia uma melhoria.**
Aurora fala o protocolo PostgreSQL; muda a string de conexão. O `ref_sync.py`
usa `psycopg` com SQL padrão (`count`, `max`, `extract(epoch …)`), sem nada
específico da implementação do PostgreSQL comunitário.

O que mudaria de fato:

| Aspecto | Hoje | Com Aurora | Precisa adaptar? |
|---|---|---|---|
| Endpoint | um só | writer e reader separados | **Sim, e vale a pena**: apontar o ref-sync para o *reader* tira a carga de leitura do primário. É melhoria que a migração **habilita** |
| Failover | reconecta manual | endpoint aponta para o novo primário | Não — o retry exponencial (1-2-4-8-16s) já cobre a janela de failover |
| Credenciais | `.env` | Secrets Manager com rotação | Sim: ler credencial no início do ciclo em vez de no boot, para rotação não exigir restart |
| Rede | rede Docker | VPC + Security Group | Não é mudança de código |
| `SOURCE(POSTGRESQL(...))` do Dictionary | host do container | endpoint do reader | Só configuração |

**O que exigiria atenção real:** o Dictionary do ClickHouse guarda host e senha
**no DDL**. Com rotação automática de credencial no Secrets Manager, o DDL
precisa ser recriado a cada rotação — ou o acesso passa a usar credencial de
leitura dedicada com ciclo de rotação longo. É o único ponto onde a migração
para Aurora força uma decisão que hoje não existe.

---

## Quais serviços AWS alavancaria para resiliência e escala?

Mapeados no diagrama `desafio-2/diagrams/02-arquitetura-aws.mmd`.

| Serviço | Para quê | Resiliência ou escala |
|---|---|---|
| **VPC + subnets privadas** | Bancos e workers sem rota para a internet; só o ALB fica na subnet pública | Resiliência (superfície de ataque) |
| **ECS Fargate** | `api`, `sync-worker`, `ref-sync` como tasks | Ambos: reinicia task morta; autoscaling de 2 a 10 tasks na API |
| **Aurora PostgreSQL Multi-AZ** | Legado com writer/reader e failover automático | Ambos: reader absorve a carga de leitura do ref-sync |
| **S3** | Destino do pgBackRest (WAL contínuo) e do backup do ClickHouse | Resiliência: RPO < 5 min, versionamento + lifecycle |
| **CloudWatch** | Logs, métricas e **alarme sobre `sync_last_success_timestamp`** | Resiliência: detecta pipeline parado em ~5 min |
| **Secrets Manager** | Credenciais com rotação, fora do `.env` | Resiliência (e conformidade) |
| **MSK** | Fila **se e quando** o volume exigir (passo 4 da seção de escala) | Escala — hoje não é necessário |
| **PrivateLink** | Acesso do Hex ao ClickHouse sem passar pela internet | Resiliência |
| **Managed Grafana** | Dashboards sem operar Grafana | Operação |

**A escolha mais importante da tabela é o alarme, não um serviço de dados.** O
incidente que mais dói em pipeline analítico não é o que derruba tudo — é o
pipeline que **para em silêncio** enquanto o dashboard segue mostrando o último
dado como se fosse atual. Por isso a métrica é um **timestamp que envelhece**
(`sync_last_success_timestamp`), não um contador de eventos: contador parado é
indistinguível de "não houve movimento"; timestamp velho é afirmativo.

---

## Consequências

### Positivas
- Freshness < 30s medido, sem carga analítica sobre o banco transacional.
- Query de painel em 7–8 ms lendo agregado, contra alvo de 1000 ms.
- Reprocessamento seguro por construção (`ReplacingMergeTree` + `_version`), testado.
- Menos peças que o desenho com Kafka: sem broker e sem connector para operar.
- Falha isolada: worker fora não derruba leitura; ClickHouse fora não perde dado
  (watermark não avança e a janela é relida).

### Negativas — o que esta escolha custa
- **`DELETE` físico não é capturado.** Detalhado acima; é a perda real frente ao CDC.
- **Código próprio no lugar de ferramenta.** Sem UI de orquestração, sem lineage
  pronto; quem opera precisa entender o mecanismo do watermark.
- **A janela de `created_at` de 7 dias cega o ciclo incremental** para UPDATE em
  transação mais antiga (estorno tardio). Mitigado por varredura completa a cada
  24h — mas é mitigação, não ausência do problema. A janela existe porque sem ela
  o planner não exclui chunk nenhum: **85.587 buffers contra 17** com o filtro.
- **Compressão e indexação se pagam uma contra a outra.** A compressão deu 23,5×
  na tabela mas **5,0× no total**, porque os 4 índices ocupam 1.484 MB contra
  1.188 MB de dado. As duas otimizações do desafio competem entre si — número
  reportado como é, não escondido.
- **Duas cópias do mesmo dado**, com custo de armazenamento e uma janela de
  divergência de segundos entre origem e destino.

---

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **CDC com Debezium** | Construída e medida. Não funciona sobre hypertable (`relispartition='f'`); rastrear 338 chunks individualmente não é operável. Preservada em `cdc-experimento` |
| **Replicação lógica nativa PG→PG** | Resolveria a captura, mas o destino é ClickHouse, não PostgreSQL — precisaria de um segundo salto de qualquer forma |
| **ETL tradicional agendado** | Latência de minutos a horas contra requisito de segundos (seção 1) |
| **Airflow / Dagster** | Orquestrador pesado para um laço de 10s com uma dependência. O custo operacional não se paga nesta escala |
| **Ler o TimescaleDB direto do ClickHouse** (`postgresql()`) | Usado no backfill inicial (12 blocos mensais em 56s), mas em regime contínuo colocaria a carga analítica de volta sobre o banco transacional — exatamente o que o desenho evita |

---

## Referências

- `desafio-2/diagrams/01-topologia-atual.mmd` — o que roda hoje
- `desafio-2/diagrams/02-arquitetura-aws.mmd` — destino em produção, com SLAs
- `desafio-2/diagrams/03-pontos-de-falha.mmd` — falhas e mitigações
- `desafio-2/pipeline/sync-worker/` — pipeline principal
- `desafio-2/pipeline/ref-sync/` — pipeline de referência
- `desafio-2/pipeline/api/` — ClickHouse servindo aplicação
- `desafio-1/REPORT.md` — medições de query, índice e compressão
