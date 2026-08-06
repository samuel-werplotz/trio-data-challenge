# Metodologia — como esta entrega foi construída

[← Voltar ao README](../README.md)

> O PDF do desafio (§ 8) diz que não é aceitável *"uso indiscriminado de IA
> generativa **sem revisão crítica** — queremos ver seu raciocínio e
> experiência, não output de LLM"*.
>
> **Usei IA generativa nesta entrega, e este documento explica exatamente
> como.** A palavra que importa na frase do PDF é *indiscriminado*. O que
> descrevo aqui é o oposto: arquitetura decidida por mim antes de qualquer
> código, IA restrita a executar dentro de contrato fechado, e todo resultado
> passando por medição antes de entrar no repositório.

---

## 1. A divisão de responsabilidade

A regra que governou a execução, em uma linha:

> **A IA escreve. A arquitetura decide. A medição julga.**

| Quem | Decide | Não decide |
|---|---|---|
| **Eu** | Schema, engine, chave de ordenação, estratégia de pipeline, o que é risco, o que entra na entrega, o que é descartado | — |
| **IA** | Sintaxe, boilerplate, primeira versão de script e de texto, varredura de casos de borda | **Nada de arquitetura.** Nenhuma escolha de engine, chave, política ou trade-off |
| **A medição** | Se a decisão sobrevive | — |

Quando a IA propôs alternativa de arquitetura, a resposta foi rejeitar ou
reformular a especificação — nunca "aceitar porque veio pronto". A ordem sempre
foi: **especificação primeiro, código depois.**

## 2. O contrato que travou o escopo antes do código

Antes de escrever a primeira linha, fechei uma especificação técnica que
definia, para cada componente: o que ele faz, qual a decisão de modelagem, qual
o critério de aceite e o que **não** se reabre durante a execução.

Isso existe por um motivo prático: **IA é excelente em produzir alternativas
plausíveis e péssima em se comprometer com uma.** Sem escopo travado, cada
sessão reabriria a mesma decisão com um desenho ligeiramente diferente, e a
entrega viraria uma colcha de retalhos coerente localmente e incoerente no todo.

Exemplos do que ficou travado antes de existir código:

| Decisão | Travada como | Por quê |
|---|---|---|
| `ORDER BY` do ClickHouse **sem** `status` | Contrato de schema | `status` é mutável; na chave, o `ReplacingMergeTree` não deduplicaria — as versões coexistiriam |
| `Decimal64(2)`, nunca `Float64` | Contrato de schema | Centavo não pode desaparecer em agregação financeira |
| `accounts` **nunca** vai ao ClickHouse | Contrato de governança | Mantém PII num único banco; simplifica LGPD e auditoria |
| Chunk de 1 dia na hypertable | Contrato de modelagem | Casa com o padrão de consulta (janelas de 24h a 90 dias) |

## 3. Como cada mudança entrava no projeto

O ciclo, aplicado a cada etapa do trabalho:

```
 1. Especifico  →  escrevo o que deve existir, o critério de aceite e como se mede
 2. Snapshot    →  commit ou volume salvo: se der errado, volto ao estado anterior
 3. IA executa  →  gera a implementação DENTRO da especificação
 4. EU REVISO   →  leio linha a linha; o que não entendo não entra
 5. MEÇO        →  rodo contra os 10M reais e comparo com o esperado
 6. Testo       →  acrescento teste de regressão à suíte
 7. Só então    →  entra no repositório
```

**O passo 5 é o que separa esta entrega de um output de LLM.** Rodar contra 10
milhões de linhas reais é o filtro que nenhum texto gerado atravessa por
plausibilidade — ou o número aparece, ou a mudança não entra.

O passo 2 não é detalhe: trabalhar com IA rápido só é seguro se voltar atrás for
barato. Snapshot antes de cada etapa é o que permitiu **descartar uma etapa
inteira** (o CDC) sem contaminar o resto.

## 4. As três coisas que a medição encontrou e a revisão não teria encontrado

Este é o argumento central deste documento. **Os três defeitos abaixo foram
encontrados rodando, não lendo** — e nenhum deles é o tipo de erro que uma IA
gera *ou* corrige sozinha, porque em todos os três o código estava
sintaticamente correto e semanticamente errado.

### 4.1 O Dictionary que resolvia 33,55% do volume

A API servia `"desconhecida"` para 66% das instituições. Causa: os códigos do
seed do legado (`001`–`015`) não batiam com os das transações (`237`, `341`,
`104`…) — só o `001` coincidia por acaso.

**Por que a revisão não pegaria:** o DDL do Dictionary estava correto, a query
estava correta, e a API respondia `200 OK`. O erro só aparece quando alguém olha
a *resposta* e pergunta por que tanta instituição é desconhecida.

**O agravante, que é a parte interessante:** a medição de "Dictionary vs JOIN"
tinha sido feita sobre esse dicionário quebrado. Um lookup que devolve o default
sai pelo caminho curto e não paga o custo real da resolução — então o
`dictGet` parecia *mais lento* do que é. Corrigido o seed, os números foram de
2,9×/empate/empate para **3,75× / 13,4× / 4,0×**.

> **Medir sobre dado que não casa mede o caminho de erro, não o caminho de uso.**

### 4.2 O pipeline que perdia dados em silêncio

Com lote acima de 50.000 linhas num mesmo `updated_at`, **10.000 de 60.000
linhas ficavam inalcançáveis** — sem erro, sem exceção, sem log. O watermark
guardava só o timestamp; num `INSERT` em massa todas as linhas compartilham o
mesmo instante, o `LIMIT` corta no meio dele, e o ciclo seguinte não tinha como
saber onde parou.

A correção foi o watermark composto `(updated_at, id)`, com a comparação por
tupla — igual à do `SELECT` e à do `ORDER BY`.

**Por que a revisão não pegaria:** o código estava correto para o caso comum. O
defeito só existe quando um único timestamp tem mais linhas que o lote — e é
exatamente por isso que o teste de saturação precisou de um patamar de 60.000.
Os quatro patamares menores passavam com folga e **teriam sustentado uma
conclusão falsa**.

### 4.3 O P95 que respondia a pergunta errada

A view de percentis reportava **P95 ≈ 55.000 s (15h)** de latência de liquidação
para instituições cujo Pix liquida em 3 segundos.

O diagnóstico inicial — meu — foi de que era artefato do gerador sintético.
**Estava errado.** O gerador sempre esteve certo (Pix mediana 1,2s, TED 45min,
boleto 18h). O defeito estava na **chave de agrupamento da view**: ela agrupava
por `(dia, instituição)` e omitia `type`, jogando quatro distribuições separadas
por cinco ordens de grandeza dentro do mesmo `percentile_cont`. Como boleto e
TED ocupam toda a cauda, o P95 do conjunto misturado *é* o P95 do boleto.

| instituição | P95 misturado | P95 do Pix | Fator |
|---|---|---|---|
| 001 | 56.176,4 s | **3,20 s** | **17.555×** |
| 033 | 56.562,8 s | **3,21 s** | 17.621× |

**Por que a revisão não pegaria:** a query nunca esteve aritmeticamente errada —
sempre devolveu o percentil correto do conjunto que lhe foi dado. É erro de
**modelagem semântica**, invisível a qualquer teste de integridade. Foi
encontrado por alguém olhando o número e perguntando *"15 horas para um Pix?"*.

> Este caso é o mais relevante dos três, porque a **primeira explicação era
> confortável e errada**. "É artefato do dado sintético" encerraria o assunto.
> Investigar em vez de aceitar é o que trocou uma desculpa por uma correção.

## 5. O que foi descartado (e por que isso importa aqui)

Uma etapa inteira — o pipeline CDC com Debezium — foi **construída, medida e
descartada**, com causa-raiz provada:

- `publish_via_partition_root` não tem efeito sobre chunk de hypertable, porque
  hypertable **não é tabela particionada nativa** (`relkind='r'`, chunk com
  `relispartition='f'`).
- Provado isolando a decodificação lógica, sem Debezium no circuito:
  `pg_logical_slot_peek_binary_changes` → **0 mudanças**; após
  `ALTER PUBLICATION ... ADD TABLE <chunk>` → **6 mudanças na hora**.

O experimento ficou no repositório sob o profile `cdc-experimento`.

**Por que isto entra num documento sobre metodologia:** IA não descarta o
próprio trabalho. Ela conclui, com muita fluência, que o que produziu funciona.
Levantar a hipótese de que a arquitetura escolhida era impossível, desenhar o
teste que isola a causa e aceitar jogar fora uma etapa pronta são decisões de
engenharia — e são o tipo de coisa que só acontece quando alguém é dono do
resultado, não do texto.

## 6. Onde a IA de fato ajudou

Sendo justo com a ferramenta, porque negar o ganho seria tão desonesto quanto
esconder o uso:

| Ganho real | Comentário |
|---|---|
| **Velocidade de boilerplate** | Dockerfiles, parsing de argumentos, formatação de saída de script |
| **Densidade de documentação** | 4.000 linhas de markdown não sairiam à mão no prazo |
| **Varredura de casos de borda** | Sugeriu verificações que eu teria deixado para depois |
| **Primeira versão de SQL complexo** | As window functions da Q4 saíram mais rápido |

O que ela **não** fez: escolher engine, definir chave de ordenação, decidir
política de retenção, priorizar risco, descartar o CDC, ou encontrar os três
defeitos da seção 4.

## 7. O que eu defendo ao vivo

Cada item abaixo eu explico sem consultar o repositório, porque a decisão foi
minha antes de virar código:

- Por que `status` fica fora do `ORDER BY` do ClickHouse, e o que aconteceria se
  entrasse.
- Por que o CDC não funciona sobre hypertable, com o teste que prova.
- Por que o watermark precisa ser `(updated_at, id)` e não só o timestamp — e
  qual bug isso corrigiu.
- Por que a compressão deu 5,0× e não os 10–20× esperados (os índices pesam
  1.484 MB contra 1.188 MB de dado).
- Por que o índice de Q2 não melhorou nada, e por que ele ficou no relatório
  mesmo assim.
- Por que percentil não pode ser materializado num continuous aggregate.
- Por que o P95 de 15h estava certo aritmeticamente e errado semanticamente.

**A prova mais forte não é este documento — é a demonstração ao vivo.** O bug do
watermark (§ 4.2) é reproduzível sob demanda: reduzo `BATCH_MAX_ROWS`, insiro um
lote acima do limite num mesmo `updated_at`, mostro a perda silenciosa na lógica
antiga e a correção na atual. Contar sobre um bug é fácil; reproduzi-lo na frente
da banca, não.

## 8. Sobre o rastro de construção

O repositório de entrega contém **produto**: código, schema, medições,
procedimentos. O andaime de construção — especificações internas, roadmap das
etapas, log de execução — foi mantido **fora** do commit final, porque é registro
de processo, não entregável.

**O rastro que ficou é o que a banca pode auditar sozinha:**

```bash
git log --oneline
```

Mais de trinta commits na ordem em que o trabalho aconteceu, incluindo o
`328e8a9` — uma etapa inteira **descartada** (o pipeline CDC). O histórico mostra
o que foi construído, em que ordem, e o que foi jogado fora — sem depender da
minha palavra, que é a propriedade que importa aqui.

O que o `git log` **não** comprime é o passo 5 do ciclo: cada número deste
repositório foi medido contra os 10 milhões de linhas. Os três defeitos da § 4
apareceram justamente aí.

---

**Resumo em uma frase:** usei IA para acelerar a execução, não para terceirizar
a engenharia — a arquitetura é minha, o código foi revisado linha a linha, cada
número foi medido contra 10 milhões de linhas reais, e os três defeitos que
importam foram encontrados por mim, medindo.
