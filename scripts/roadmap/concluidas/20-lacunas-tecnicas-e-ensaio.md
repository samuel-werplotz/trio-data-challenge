# 20 — LACUNAS TÉCNICAS E ENSAIO  [carga-real]

> **Etapa criada na revisão de entrega.** Junta as lacunas técnicas menores
> (§ 4.5) com as **2 das 5 perguntas previstas que hoje não têm resposta
> escrita** (§ 5): "novo consumer sem impactar as aplicações" e "migrar engine
> de tabela ClickHouse em produção sem downtime". Estão na mesma etapa porque
> são o mesmo trabalho: as duas perguntas se respondem com **procedimento
> escrito**, e o resto da lista são medições que faltam. Sem ensaio, a defesa ao
> vivo depende de improviso sobre a parte mais técnica do desafio.

## ORIGEM
Revisão de entrega § 4.5 (5 lacunas técnicas) e § 5 (prontidão para apresentação: 2 perguntas descobertas + 3 riscos de defesa ao vivo); PDF § 7 (perguntas de aprofundamento); `99-validacao-final.md` § As 5 perguntas previstas (respostas hoje em 1 linha cada); `desafio-2/ADR.md` § escala

## IMPEDITIVOS
- [ ] ambiente completo de pé com os 10M carregados — o teste de saturação e o ensaio de `EXCHANGE TABLES` precisam do dataflow real

## ESTADO HERDADO
Verificado ao fechar a **etapa 19**:
- **Baseline da suíte: 227 pass / 0 fail / 3 skip** (os 3 SKIP são `make`). Cresceu de 207 com o bloco 19 (20 testes).
- **O ClickHouse foi recriado nesta etapa** (`docker compose up -d clickhouse`, para montar `named_collections.xml`) e o dado sobreviveu: **10.000.000 nas 3 pontas**, conferido antes e depois. Precedente útil para o passo 2 da 20: recriar container com volume existente é seguro; o que **não** sobrevive é `init/` — ele só roda em volume novo.
- **RBAC persiste no volume** (`/var/lib/clickhouse/access/`): `analytics_ro` sobreviveu à recriação sem ser recriado. Relevante para o plano de HA (passo 4) — ao migrar para `Replicated*`, o acesso é estado a considerar, não só o dado.
- **`analytics_ro` existe e nega o que deve negar**, com `readonly=1` impedindo o próprio usuário de elevar limite. O **teste de saturação (passo 3) deve rodar com o usuário `trio`**, não com `analytics_ro` — o teto de 60 s e 50M linhas abortaria a carga antes de saturar.
- **Trilha de leitura de PII implementada** (`pii_access_log` + `read_accounts_audited`), append-only por gatilho. Se o passo 5 (cenário de Q4) tocar em `accounts`, o acesso fica registrado — o que é o comportamento correto, mas vai gerar linha no log a cada execução do cenário.
- **Cuidado herdado, agora com dois precedentes**: teste que assere valor literal quebra ou reverte quando o dado legítimo muda (`14.4` revertia o Dictionary na 17.5; `16.9` prendia-se a "0,018"). O cenário de Q4 planta dado sintético — **os testes dele devem asserir propriedade** (a detecção dispara, o dado é limpo), não valores fixos.
- **A pergunta 3 do PDF ("migrar engine sem downtime") tem um insumo novo**: `EXCHANGE TABLES` é atômico e está disponível nesta versão (24.8); a resposta de 1 linha em `99-validacao-final.md` ainda cita `RENAME`, que é o caminho em dois tempos.
- Ambiente: 11 containers de pé, legado com 480/80.000/50.000/15, Dictionary resolvendo 100%.

Verificado ao fechar a etapa 16 (segue válido):
- **ClickHouse é nó único com `MergeTree`/`ReplacingMergeTree`, sem `Replicated*`.** Migrar engine para `ReplicatedReplacingMergeTree` em produção **é exatamente a pergunta 3 do PDF** — e o repositório não tem o procedimento escrito. A resposta atual em `99-validacao-final.md` tem 1 linha e cita `RENAME`; o caminho correto e atômico é `EXCHANGE TABLES`.
- **Freshness de ~10 s foi medida em regime ocioso.** O ADR projeta 10× no papel. **Não existe nenhum experimento de saturação** — a pergunta "e a 5.800 escritas/s?" hoje não tem número, só projeção.
- **Duas cicatrizes reais de MV já registradas** e que são o material da pergunta 2 (novo consumer): etapa 12 duplicou 10M porque a MV-gatilho já estava ativa quando o `INSERT SELECT` rodou; etapa 16 deixou raw e MV divergentes ao deletar só na raw. **Usar a cicatriz é mais forte do que teorizar** — o procedimento de "MV nova sobre tabela quente" nasce dela.
- **`scripts/backfill-clickhouse.sh` já checa se a tabela tem linhas antes do `INSERT SELECT`** — guarda criada após o incidente da etapa 12. É a base do procedimento de backfill sem duplicar.
- **P95 ≈ 15h é artefato do gerador**, já declarado no `REPORT.md`. Parece erro à primeira vista e a banca vai reparar. Falta a **resposta de 20 segundos** ensaiada.
- **Q4 (detecção de anomalia) retorna 0 linhas** contra o dataset atual, o que é o resultado correto — mas "0" na demo vira dúvida sobre a query. Não há cenário plantado que demonstre a detecção funcionando.
- **`run_all.sh` tem 171 pass / 0 fail / 3 SKIP**, e os 3 SKIP são `make` ausente **neste** Windows. Nunca foi rodado em ambiente limpo por terceiro. O critério de aceite nº 1 do PDF (`docker compose up -d` sobe tudo sem erro) é **binário** — passa ou não passa.
- **Percentis vêm de `percentile_cont` em view** porque `timescaledb_toolkit` não existe na imagem fixada (etapa 08). Em produção com Timescale Cloud o toolkit **existe** — falta a linha dizendo que lá o CAgg passa a materializar com `percentile_agg`.
- **`accounts` fora do ClickHouse** já é tratado na etapa 18 (trade-off de Q2). Aqui só se confere que não ficou duplicado nem contraditório entre os documentos.

## ESCOPO
Faz: escreve os 2 procedimentos que respondem as perguntas descobertas, mede a saturação do pipeline, planta o cenário de Q4, escreve o plano de HA do ClickHouse, fecha as notas pendentes (toolkit) e valida a sequência do zero.
Não faz: não implanta réplica de ClickHouse no ambiente local (recurso e escopo); não reescreve o pipeline para aguentar 10× — mede e reporta o que aguenta hoje.

## PASSOS
1. **Procedimento: novo consumer sem impactar as aplicações** (`desafio-2/ADR.md` ou documento próprio linkado por ele). MV nova sobre tabela quente: impacto no merge, custo de escrita adicional, backfill por `INSERT SELECT` **sem duplicar o que a MV-gatilho já capturou** — com a janela de corte explícita. Referenciar as duas cicatrizes por commit e etapa; é a evidência de que o procedimento nasceu de erro real, não de blog.
2. **Procedimento: migrar engine em produção sem downtime.** `MergeTree` → `ReplicatedReplacingMergeTree`, passo a passo: tabela sombra com a engine nova → dupla escrita → backfill do histórico → **validação de contagem por partição** → `EXCHANGE TABLES` (atômico, não `RENAME` em dois tempos) → janela de segurança → remoção da antiga. Incluir o ponto de rollback de cada passo e o que fazer se a validação divergir.
3. **Teste de saturação do pipeline.** Gerar escrita crescente na origem (patamares, ex.: 500 → 1.000 → 3.000 → 5.800 escritas/s) e medir em cada patamar: lag do watermark, freshness real, uso de CPU/memória do worker, taxa de erro. Registrar **onde satura e qual é o primeiro recurso a estourar**. Reportar o número medido mesmo que fique abaixo do alvo — mesma regra do "índice que não melhorou" da etapa 07.
4. **Plano de HA do ClickHouse, escrito.** Por que o desafio roda em nó único, o que muda em produção (Keeper, `Replicated*`, `ON CLUSTER`, shard por instituição), qual o caminho de migração a partir do estado atual (usa o passo 2) e qual o custo — casar com o `docs/CUSTO-AWS.md` da etapa 17.
5. **Cenário plantado para Q4.** Inserir um conjunto sintético e identificável que dispara a detecção de anomalia, com script que **planta, demonstra e limpa** — mesmo padrão de `retention-demo.sh` e `lgpd-erasure-demo.sh`. Conferir contagem antes e depois nas 3 pontas (raw + 2 MVs por `countMerge`); a etapa 16 mostrou que mexer na raw sem tratar a MV desincroniza.
6. **Nota do toolkit em produção.** Uma linha no `REPORT.md` e na tabela de limitações do `99-validacao-final.md`: em produção com Timescale Cloud, `timescaledb_toolkit` existe, o CAgg passa a materializar `percentile_agg` e a view deixa de ser necessária. É limitação **do ambiente**, não do desenho.
7. **Validar a sequência do zero em ambiente limpo.** `nuke` → `up` → `seed` → `check`, cronometrado, com os 3 SKIP investigados: se são só `make` ausente, declarar; se algum esconder falha real, virou defeito. Rodar num diretório limpo (clone do repositório), não no diretório de trabalho — é assim que o avaliador vai rodar.
8. **Ensaio das respostas de risco.** Escrever, no roteiro de demonstração, a resposta de **20 segundos** para: (a) por que o P95 ≈ 15h é artefato do gerador e o que ele **não** significa; (b) por que Q4 devolve 0 e como demonstrar que detecta (passo 5); (c) `git log` aberto na demo — 25 commits com desvio registrado é a melhor defesa contra "isso é saída de LLM".
9. Acrescentar o bloco `# --- 20 lacunas-tecnicas-e-ensaio ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] Procedimento "novo consumidor" escrito, com o instante de corte, backfill sem duplicar e as 2 cicatrizes (etapas 12 e 16) referenciadas — teste `20.3`
- [x] Procedimento "migração de engine sem downtime" com `EXCHANGE TABLES` (atômico) e rollback por passo — testes `20.1`/`20.2`
- [x] Teste de saturação **executado**, 5 patamares, entrega conferida **por patamar** — testes `20.4`/`20.4b`. **Zero perda em 70.300 linhas, lag máximo 19,2 s**
- [x] Plano de HA escrito, ligado ao procedimento e ao custo ($280 → $1.120/mês) — teste `20.11`
- [x] Cenário de Q4 planta, demonstra (**0 → 2 detecções**) e limpa — testes `20.9`/`20.6`
- [x] Nota do toolkit em produção no `REPORT.md` — teste `20.7`
- [x] Clone limpo validado: compose parseia, 13 serviços resolvem, os 12 entregáveis presentes, DDL sem segredo. **Ver desvio 3** — a validação achou um defeito no `audit.sh`
- [x] As 5 perguntas do PDF desenvolvidas, com número e procedimento — teste `20.10`

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 20.1 | local | `grep -ci 'EXCHANGE TABLES' desafio-2/ADR.md docs/` | ≥ 1 |
| 20.2 | local | `grep -ci 'ReplicatedReplacingMergeTree' desafio-2/ADR.md docs/` | ≥ 1 |
| 20.3 | local | `grep -ci 'novo consumer' desafio-2/ADR.md docs/` | ≥ 1 |
| 20.4 | local | arquivo de resultado do teste de saturação existe e tem ≥ 3 patamares | sai 0 |
| 20.5 | carga-real | script do cenário de Q4 | Q4 devolve ≥ 1 linha durante a demo |
| 20.6 | carga-real | contagens após a limpeza do cenário de Q4 (raw + 2 MVs) | 10.000.000 nas 3 |
| 20.7 | local | `grep -ci 'percentile_agg' desafio-1/REPORT.md` | ≥ 1 (nota de produção) |
| 20.8 | local | `grep -ci 'artefato do gerador\|p95' <roteiro de demonstração>` | ≥ 1 |
| 20.9 | carga-real | sequência do zero em clone limpo (`nuke`→`up`→`seed`→`check`) | sai 0, com tempos registrados |
| 20.10 | local | as 5 perguntas do PDF respondidas com ≥ 5 linhas cada | sai 0 |

## ROLLBACK
```bash
# o cenário de Q4 é plantado e limpo pelo próprio script; se ficar resíduo:
bash <script-do-cenario> --cleanup
git checkout -- desafio-1/REPORT.md desafio-2/ADR.md scripts/roadmap/99-validacao-final.md
```
> **Passos 3 e 5 escrevem no banco.** O teste de saturação usa faixa de `external_id`
> identificável e removível; o cenário de Q4 limpa o que planta. Conferir as 3 pontas depois
> dos dois — raw e MVs desincronizam com facilidade (etapas 12 e 16).

## STATUS
Estado: CONCLUÍDA

Premissas assumidas:
- **Teste de carga precisa de um patamar que quebre alguma coisa.** Cinco patamares que passam provam menos que um que falha: o de 60.000 (acima de `BATCH_MAX_ROWS`) é o único que exercita a retomada dentro de um mesmo `updated_at`, e é o que justifica o teste existir.
- **Procedimento nasce de cicatriz, não de blog.** Os dois documentos citam etapa e sintoma dos erros reais (duplicação de 10M na 12, divergência MV/raw na 16). É o que separa procedimento defensável de procedimento plausível.
- **Não subir Keeper local.** Três Keepers na mesma máquina demonstram configuração, não a propriedade — failover real exige derrubar um nó e provar que a leitura continua. Plano escrito com custo calculado é mais honesto que encenação que não sobrevive a "e se a AZ cair?".
- **A validação em clone limpo cobre o que é verificável sem derrubar o ambiente.** Compose, serviços, entregáveis e ausência de segredo foram conferidos no clone; o `up -d` completo exigiria parar os 11 containers com os 10M carregados, e o `nuke` está fora do que esta etapa pede.

Desvios do plano:
1. **O passo 3 encontrou perda silenciosa de dados e parou a etapa.** O teste de saturação revelou que o pipeline travava e descartava o excedente com lote acima de `BATCH_MAX_ROWS`. Virou a **etapa 20.5**, corrigida e testada antes de a 20 continuar. Segundo defeito de produto achado medindo — o primeiro foi o Dictionary a 33,55% (17.5).
2. **A primeira versão do teste de saturação não saturava, e teria produzido uma conclusão falsa.** Os 4 patamares originais (500 → 5.800/s) passavam com folga porque `INSERT` em massa escreve 5.800 linhas em 0,43 s — nenhum chegava perto do lote. O script teria reportado "aguenta o pico do cenário 10×": verdadeiro e enganoso. O patamar de 60.000 e a coluna de entrega **por patamar** ficaram permanentes.
3. **A validação em clone limpo achou um defeito no `audit.sh`.** Rodando de um clone, `A2.1` falhou: esperava 24 arquivos de etapa e achou 25 — eu havia criado a 20.5 sem atualizar o contador. **É exatamente o tipo de coisa que só aparece rodando de fora do diretório de trabalho**, e é o argumento a favor do passo 7. Corrigido para 25, com a 20.5 no laço de conferência. As outras 2 falhas do clone (`A1.9` exige containers, `A7.6` compara o caminho do git root) são propriedades de rodar fora do lugar, não defeitos.
4. **`EXCHANGE TABLES` substituiu `RENAME` na resposta da pergunta 3.** A resposta de 1 linha em `99-validacao-final.md` citava `RENAME` atômico — mas `RENAME` em dois tempos tem um instante em que a tabela não existe e toda consulta falha. O `EXCHANGE` é que é atômico.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (blocos `# --- 20.5 ... ---` e `# --- 20 ... ---`, 18 testes)
- [x] run_all.sh sem FAIL — **245 pass, 0 fail, 3 skip**
- [x] ESTADO HERDADO da próxima (21) preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → registrados em `99-validacao-final.md`
- [x] Commit checkpoint
- [x] Mover pra concluidas/. Marcar [x] no CLAUDE.md
