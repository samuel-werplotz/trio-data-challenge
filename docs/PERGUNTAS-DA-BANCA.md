# As 5 perguntas da apresentação — respostas

[← Voltar ao README](../README.md)

O PDF § 7 antecipa cinco perguntas de aprofundamento. Cada uma abaixo tem a
resposta curta (o que eu diria em 30 segundos) e o detalhe técnico que sustenta.

---

## 1. "E se o volume triplicasse, o que mudaria na arquitetura?"

**Resposta curta:** nada de imediato — 3× são 30 milhões de linhas, e nem o
TimescaleDB nem o ClickHouse sentem isso. O que muda é a ordem em que os quatro
movimentos de escala do [ADR](../desafio-2/ADR.md) entram.

**O detalhe:**

| Componente | A 3× | Quando dói |
|---|---|---|
| **TimescaleDB** | Chunk de 1 dia continua adequado; compressão dá mais retorno | Quando o chunk diário passar de ~25 % da RAM |
| **ClickHouse** | Irrelevante — a MV agrega **na ingestão**, o custo cresce com o que entra, não com o acumulado | Quando o dado deixar de caber num nó (aí entra shard) |
| **sync-worker** | `BATCH_MAX_ROWS` de 50.000 absorve; o teste de saturação entregou 60.000 sem perda | Quando uma rajada num único `updated_at` exceder o lote de forma recorrente |

**A ordem correta dos movimentos** (e por que fila é o último):

1. **Particionar a leitura** — N workers com um watermark por faixa de
   `source_institution`. Escala linear, sem coordenação, sem mudar schema.
2. **Aumentar o lote antes da frequência.** O ClickHouse prefere poucos INSERTs
   grandes: cada INSERT vira uma *part*, e parts demais causam `too many parts`.
3. **Deixar o peso nas MVs** — a query de painel lê 5.882 linhas em vez de 10M.
4. **Só então fila (MSK).** Custa ≈ US$ 620/mês, **73 % do custo atual da
   plataforma inteira**. Os três passos anteriores resolvem sem ela.

> O que eu **não** faria a 3×: introduzir Kafka. É a resposta reflexa e a errada
> — resolve um problema de desacoplamento que não existe nesta escala.

---

## 2. "Como adicionaria um novo consumer no ClickHouse sem impactar as aplicações existentes?"

**Resposta curta:** MV nova apontando para tabela nova. MV no ClickHouse é
**gatilho de inserção**, não view — ela lê o bloco que está entrando, não a
tabela inteira, então acrescentar uma não toca em nada que já existe.

**O procedimento**, detalhado em
[`PROCEDIMENTOS-PRODUCAO.md`](../desafio-2/PROCEDIMENTOS-PRODUCAO.md):

```sql
-- 1. Tabela de destino do novo consumidor (nunca ENGINE na própria MV).
CREATE TABLE trio_analytics.novo_agregado (...) ENGINE = AggregatingMergeTree() ...;

-- 2. MV que alimenta só a tabela nova. A partir daqui, dado NOVO já flui.
CREATE MATERIALIZED VIEW trio_analytics.mv_novo TO trio_analytics.novo_agregado AS ...;

-- 3. Backfill do histórico, UMA vez, com a MV já ativa.
INSERT INTO trio_analytics.novo_agregado SELECT ... FROM transactions_raw WHERE created_at < <corte>;
```

**As duas armadilhas, ambas vividas neste projeto:**

- **`POPULATE` não.** Ele pode perder linhas inseridas *durante* a criação. Com
  tabela separada, o backfill roda sob controle e é reexecutável.
- **A ordem do backfill importa.** As MVs deste projeto já estavam ativas quando
  o backfill do raw rodou — elas capturaram os 12 blocos sozinhas. Rodar o
  `INSERT SELECT` depois **duplicou tudo: 20M em vez de 10M**. O
  `backfill-clickhouse.sh` agora checa se a tabela de agregação já tem linhas.

**Impacto nas aplicações existentes:** nenhum na leitura. O único custo real é
**escrita** — cada MV a mais é trabalho extra por bloco inserido. Com muitas
MVs, o `INSERT` fica mais lento. É o limite prático, não a leitura.

---

## 3. "Como faria a migração de engine de uma tabela ClickHouse em produção sem downtime?"

**Resposta curta:** tabela sombra com a engine nova, dupla escrita por MV,
backfill por partição, validação **por partição**, e `EXCHANGE TABLES` — que é
atômico.

```sql
-- 1. Tabela nova com a engine de destino.
CREATE TABLE transactions_raw_new (...) ENGINE = ReplicatedReplacingMergeTree(...) ...;

-- 2. Dupla escrita: o que entrar a partir de agora vai para as duas.
CREATE MATERIALIZED VIEW mv_dupla TO transactions_raw_new AS SELECT * FROM transactions_raw;

-- 3. Backfill do histórico, partição a partição (não de uma vez).
INSERT INTO transactions_raw_new SELECT * FROM transactions_raw WHERE toYYYYMM(created_at) = 202608;

-- 4. Validar POR PARTIÇÃO — contagem e checksum, não só o total.
SELECT toYYYYMM(created_at) p, count(), sum(cityHash64(external_id)) FROM ... GROUP BY p;

-- 5. Troca ATÔMICA. Não é DROP + RENAME: não há instante sem tabela.
EXCHANGE TABLES transactions_raw AND transactions_raw_new;

-- 6. Remover a MV de dupla escrita e, após a janela de segurança, a tabela antiga.
```

**Por que `EXCHANGE TABLES` e não `RENAME`:** o `RENAME` em dois passos deixa uma
janela — curta, mas real — em que a tabela de produção não existe. `EXCHANGE` é
uma operação atômica no metadata.

**Por que validar por partição e não no total:** contagem total igual esconde
compensação entre partições (uma a mais aqui, uma a menos ali). Foi por não
validar assim que o backfill duplicado passou despercebido no primeiro momento.

**Ordem entre tabelas:** MVs de agregação primeiro (menores, e um erro se
corrige com `TRUNCATE` + backfill), a `transactions_raw` por último.

---

## 4. "Qual sua estratégia para onboardar um Data Champion novo que precisa criar queries no Grafana?"

**Resposta curta:** acesso restrito por perfil no dia 1, um guia que responde
sozinho, e limites de custo **aplicados no servidor** — não confiados à
disciplina de quem consulta.

Detalhado em [`DATA-CHAMPIONS.md`](DATA-CHAMPIONS.md). Os quatro pilares:

| Pilar | O que é |
|---|---|
| **Acesso** | Perfil `analytics_ro` — somente leitura, sem DDL, com quota de linhas e de tempo por query |
| **Guia** | Onde está cada métrica, quais tabelas usar (as MVs, não a raw) e as consultas mais pedidas já prontas |
| **Limites no servidor** | `max_execution_time`, `max_rows_to_read`, `max_memory_usage` no perfil. Uma query ruim é barrada pelo motor, não por bom senso |
| **Limitação declarada** | `accounts` **não existe** no ClickHouse. Pergunta que cruza transação com dado de titular só é respondível no TimescaleDB, com acesso nominal |

**A parte de liderança técnica, que é o que a pergunta realmente cobra:** o
gargalo de um Data Champion novo raramente é SQL — é **não saber qual tabela
responde a pergunta dele**. Por isso o guia começa por pergunta de negócio
("qual o volume de Pix por instituição hoje?") e leva à tabela, não o contrário.

E a regra que evita a proliferação de queries quase-iguais: **query que três
pessoas pedem vira painel provisionado**, versionado em `init/grafana/`. Sem
isso, em seis meses existem quinze variações da mesma métrica, cada uma com um
número ligeiramente diferente — e aí a plataforma perde a confiança do negócio.

---

## 5. "Se precisasse migrar o PostgreSQL legado para Aurora amanhã, qual seria seu plano de 72h?"

**Resposta curta:** replicação lógica nativa (origem e destino são ambos
PostgreSQL 16), com `pg_dump` como plano B — são só 86 MB. Plano completo em
[`migration-analysis.md`](../desafio-1/migration-analysis.md).

**A linha do tempo:**

| Janela | O quê |
|---|---|
| **T-24h** | Provisionar Aurora Multi-AZ na mesma VPC. Schema por `pg_dump --schema-only`. Publication na origem, subscription no destino — a cópia inicial roda **antes** da janela |
| **T-2h** | Validar: contagem **e checksum de valor** por tabela. Lag da replicação em zero |
| **T-0** | Aplicação em read-only → lag zera → `setval()` em **todas** as sequências → repontar conexão (leitura para o **reader endpoint**) → `ANALYZE` → liberar escrita |
| **T+0 a 2h** | Validação intensiva. Legado **de pé**, em read-only, não desligado |
| **T+2h** | Replicação reversa (Aurora → legado) — é o que torna o rollback real em vez de teórico |
| **T+72h** | Sem incidente: legado desativado, com snapshot final |

**Os dois pontos que derrubam esse tipo de migração:**

1. **Sequências não migram.** A replicação lógica copia linhas, não o estado das
   sequências. O destino fica com todo o dado e `nextval()` em 1 — violação de
   PK na primeira inserção. `setval()` em cada sequência antes de liberar
   escrita. *(Este projeto já esbarrou nessa classe de erro no seed do legado.)*
2. **Estatísticas não migram.** Sem `ANALYZE`, o planner do destino começa cego.
   É o risco medido neste próprio repositório: o planner estimava **509.298
   linhas onde havia 80.000**, por contar linha morta como viva.

**O critério de aborto, decidido antes do corte** — sem isso a decisão vira
discussão sob pressão:

| Sintoma | Ação |
|---|---|
| Divergência de contagem ou checksum | **Aborta**, não corta |
| Lag não zera em 15 min | **Aborta**, reagenda |
| Erro de aplicação após o corte | Rollback imediato |
| Latência > 2× a linha de base | Rollback se não normalizar em 30 min |

**Sobre o pipeline:** o `ref-sync` sobrevive **sem alteração de código** — Aurora
fala o protocolo PostgreSQL. E ganha uma melhoria: apontar para o *reader
endpoint* tira a carga de leitura do primário. O único ponto de atenção real é
que o Dictionary do ClickHouse guarda host e senha **no DDL**, então rotação
automática de credencial exige recriar o DDL ou usar credencial de leitura
dedicada com ciclo longo.
