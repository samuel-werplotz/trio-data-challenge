# 18 — DATA CHAMPIONS  [compose]

> **Etapa criada na revisão de entrega.** É o gap mais caro em nota por linha
> escrita. O PDF cita **Data Champions em 4 seções**, cita **Hex duas vezes**, e
> a apresentação traz a pergunta direta *"qual sua estratégia para onboardar um
> Data Champion novo?"*. A entrega atual justifica o `ORDER BY` pelos padrões de
> consulta deles e **não entrega nada mais**: nenhum guia, nenhuma query-modelo,
> nenhuma convenção de acesso, nenhum limite de custo de query.
> É o eixo de **liderança técnica** — a parte que separa "engenheiro sênior" de
> "dono do projeto de dados".

## ORIGEM
Revisão de entrega § 4.3; PDF § Data Champions (4 ocorrências) e § Hex (2 ocorrências); PDF § 7 pergunta 4; `init/clickhouse/01_schema.sql` (MVs e Dictionary a catalogar); `desafio-1/queries/grafana_pix_24h_vs_d1.sql` (modelo de query já validado, 12 ms)

## IMPEDITIVOS
- [ ] ClickHouse de pé com as 2 MVs populadas — necessário para medir as queries-modelo e testar os limites de `max_execution_time`/`max_memory_usage` de verdade, não no papel

## ESTADO HERDADO
Verificado ao fechar a **etapa 17**:
- **Baseline real da suíte é 186 pass / 0 fail / 3 skip**, não os 171 que a esteira registrava desde a 16. A diferença não é regressão: 171 foi medido com parte dos testes de carga-real em SKIP. São 155 testes numerados + 34 do bloco E (etapa 13.5); os 3 SKIP são `make` ausente neste Windows.
- **Existe camada executiva agora**: `docs/SUMARIO-EXECUTIVO.md` (69 linhas) e `docs/CUSTO-AWS.md`. **O sumário já promete o que esta etapa entrega** — "Data Champions operando por conta própria, com o catálogo de dados e o acesso via Hex estabelecidos" está no bloco de 90 dias, e "guia do Data Champion publicado, com limites de custo de query aplicados no servidor" no de 30 dias. Documento executivo que promete e não entrega é pior do que não prometer.
- **`docs/` deixou de estar vazio** — 3 arquivos (`SUMARIO-EXECUTIVO.md`, `CUSTO-AWS.md`, `INVENTARIO-STARTER.md`). Sem colisão com `DATA-CHAMPIONS.md`.
- **Custo de query dos Data Champions tem número agora**: Managed Grafana a $77/mês em A (3 editores + 10 viewers) e $195 em B (5 + 30); PrivateLink para o Hex a $17/mês. A seção de limites desta etapa pode referenciar o custo real de uma query cara, não só a mecânica.
- **O ClickHouse do cenário A é `m6i.2xlarge` (8 vCPU/32 GB)** no TCO, e o `CUSTO-AWS.md` declara que a classe é o item de maior peso (33% do cenário A) e **depende do teste de saturação da etapa 20**. Os limites de `max_memory_usage` desta etapa precisam ser coerentes com 32 GB, não com a máquina local.
- **Ambiente de pé e conferido nesta etapa**: 11 containers, `transactions_raw` com 10.000.000.

Verificado ao fechar a etapa 16 (segue válido):
- **Duas MVs agregadas existem e estão em 10.000.000 (`countMerge`)**: `daily_by_institution` e `status_funnel`, ambas `AggregatingMergeTree` alimentadas por MV-gatilho sobre `transactions_raw`. **É esse o catálogo a escrever** — hoje elas só existem no DDL.
- **Armadilha central a documentar, já sofrida duas vezes na esteira**: MV no ClickHouse é **gatilho de inserção**, não view que recalcula. Etapa 12 duplicou 10M com `INSERT SELECT` sobre MV já ativa; etapa 16 deixou raw e MV divergentes ao rodar `ALTER TABLE ... DELETE` só na raw. Um Data Champion que ler a MV como "view que sempre reflete a raw" vai errar — **isso precisa estar escrito no guia, não só nos desvios**.
- **Ler estado agregado exige `-Merge`**: `countMerge(cnt)`, `avgMerge(...)`. `SELECT cnt FROM daily_by_institution` devolve binário ilegível. É o erro nº 1 de quem chega no ClickHouse vindo do Postgres.
- **`countIfMerge` sobre `countState()` puro dá `ILLEGAL_TYPE_OF_ARGUMENT`** (desvio da etapa 12) e **agregação aninhada dá `ILLEGAL_AGGREGATION`** (desvio da etapa 14, resolvido com subconsulta). As duas são armadilhas reais e viraram queries-modelo comentadas.
- **`dict_institutions` funciona e está medido**: `dictGetOrDefault` a 0,018 s contra 0,054 s da JOIN equivalente no lookup por linha, **empate em `GROUP BY`** — os dois números vão ao guia, não só o favorável.
- **`accounts` (a tabela com PII) nunca foi ao ClickHouse**, por design de S01. Consequência prática que ninguém declarou ainda: **Q2 (reconciliação com dados de conta) só é respondível no TimescaleDB** — o Data Champion não a responde no motor analítico. Trade-off a declarar nesta etapa.
- **Senha do ClickHouse hoje é `trio2024`, em claro no compose e no DDL do Dictionary**, e existe um único usuário. Não há perfil separado. Esta etapa **descreve** a convenção de acesso; a matriz de perfis é entrega da etapa 19 — as duas se referenciam, não se duplicam.
- **A API FastAPI (`:8000`) já serve o ClickHouse em JSON** — é o caminho para quem não escreve SQL, e precisa aparecer no guia como alternativa ao acesso direto.
- Query do painel Grafana medida em **12 ms** contra alvo de 1000 ms: serve de referência do que é uma query "barata" neste cluster.

## ESCOPO
Faz: escreve o guia do Data Champion — acesso, catálogo das MVs, queries-modelo comentadas e medidas, quando usar MV vs raw, limites de custo de query e escalonamento. Trata Hex explicitamente.
Não faz: não cria usuário nem perfil no ClickHouse (é a etapa 19); não cria MV nova (mudança de schema trava pela Seção 5); não integra o Hex de verdade — não há conta, então é caminho documentado.

## PASSOS
1. **`docs/DATA-CHAMPIONS.md` — como pedir acesso.** Qual o caminho (quem aprova, qual perfil, qual endpoint), o que vem por padrão e o que exige justificativa. Apontar para a matriz de perfis da etapa 19 em vez de redefini-la aqui.
2. **Catálogo das MVs — o que cada uma responde E o que ela NÃO responde.** Uma seção por MV (`daily_by_institution`, `status_funnel`): grão, colunas, chave de agregação, latência típica e **as perguntas que ela não responde** (a segunda metade é a que evita a pergunta errada na tabela errada). Incluir `transactions_raw` e o `dict_institutions` no mesmo catálogo.
3. **3 queries-modelo comentadas, medidas contra o cluster real.** Cada uma com o tempo real ao lado. Cobrir os três padrões: (a) leitura de estado agregado com `-Merge`; (b) enriquecimento com `dictGetOrDefault` em vez de JOIN; (c) recorte na raw quando a MV não serve, com filtro de partição para não varrer 12 meses. Comentário de **intenção** em cada bloco, conforme a Seção 6 do `CLAUDE.md`.
4. **Quando usar MV e quando usar raw** — regra de decisão curta, não ensaio. Incluir a armadilha do `-Merge`, a de MV-como-gatilho (não recalcula ao mudar a raw) e as duas de agregação (`countIfMerge`, agregação aninhada), cada uma com o erro literal que o ClickHouse devolve — é assim que se acha a resposta pelo `Ctrl+F`.
5. **Limites e controle de custo.** `max_execution_time`, `max_memory_usage`, `max_rows_to_read`, `max_bytes_before_external_group_by`. Valor sugerido por perfil, **o que o usuário vê quando estoura** e como pedir exceção. Testar os limites contra o cluster e registrar a mensagem real de erro.
6. **Hex.** O PDF cita duas vezes e o repositório o ignora. Escrever a seção: como o Hex se conecta ao ClickHouse (driver, host, porta, usuário read-only), qual perfil usar, quais MVs expor como fonte, e por que a query de notebook deve bater na MV e não na raw. Declarar que **não foi executado** — não há conta neste ambiente — e o que seria necessário para validar.
7. **Escalonamento.** Query lenta → o quê. Dado que parece errado → o quê. Acesso negado → o quê. Com o dono de cada caminho e o prazo esperado.
8. **Declarar o trade-off do `accounts`.** Q2 (reconciliação com dados de conta) só existe no TimescaleDB porque PII não vai ao ClickHouse. Escrever no guia e no `REPORT.md`: qual pergunta o Data Champion **não** responde no motor analítico, e qual é o caminho (API ou acesso ao Timescale com perfil restrito).
9. Acrescentar o bloco `# --- 18 data-champions ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] `docs/DATA-CHAMPIONS.md` existe e cobre os 7 tópicos — testes `18.1`–`18.9`
- [x] Catálogo lista as 2 MVs + raw + Dictionary, cada um com **o que responde e o que não responde** — testes `18.6`/`18.7`
- [x] 3 queries-modelo com tempo real medido (**5 ms**, **4 ms**, **6 ms**) e **executadas pelos testes** `18.10a/b/c`, não só citadas
- [x] Limites nomeados com valor sugerido e a **mensagem literal** capturada do cluster (`TIMEOUT_EXCEEDED`, `TOO_MANY_ROWS`, `MEMORY_LIMIT_EXCEEDED`) — testes `18.11`/`18.11b` forçam a falha de verdade
- [x] Hex com seção própria, caminho de conexão e declaração de que **não foi executado** — teste `18.2`
- [x] Trade-off do `accounts`/Q2 declarado no guia **e** em seção nova do `REPORT.md` — teste `18.12`
- [x] Armadilha de MV-como-gatilho documentada nas duas direções — teste `18.13`

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 18.1 | local | `test -f docs/DATA-CHAMPIONS.md` | sai 0 |
| 18.2 | local | `grep -ci 'hex' docs/DATA-CHAMPIONS.md` | ≥ 1 |
| 18.3 | local | `grep -ci 'max_execution_time' docs/DATA-CHAMPIONS.md` | ≥ 1 |
| 18.4 | local | `grep -ci 'max_memory_usage' docs/DATA-CHAMPIONS.md` | ≥ 1 |
| 18.5 | local | `grep -c 'countMerge\|avgMerge' docs/DATA-CHAMPIONS.md` | ≥ 2 |
| 18.6 | local | `grep -ci 'daily_by_institution' docs/DATA-CHAMPIONS.md` | ≥ 1 |
| 18.7 | local | `grep -ci 'status_funnel' docs/DATA-CHAMPIONS.md` | ≥ 1 |
| 18.8 | local | `grep -ci 'dictGet' docs/DATA-CHAMPIONS.md` | ≥ 1 |
| 18.9 | local | `grep -ci 'escalonamento\|escalar dúvida' docs/DATA-CHAMPIONS.md` | ≥ 1 |
| 18.10 | carga-real | executar as 3 queries-modelo extraídas do guia contra o ClickHouse | as 3 saem 0 e devolvem linha |
| 18.11 | carga-real | query com `max_execution_time=1` sobre a raw inteira | falha com `TIMEOUT_EXCEEDED` (limite funciona de fato) |
| 18.12 | local | `grep -ci 'accounts' desafio-1/REPORT.md` \| trade-off de Q2 | ≥ 1 |

## ROLLBACK
```bash
rm -f docs/DATA-CHAMPIONS.md
git checkout -- desafio-1/REPORT.md
```
> As queries-modelo são somente leitura; o teste de limite falha por design e não escreve nada.

## STATUS
Estado: CONCLUÍDA

Premissas assumidas:
- **Query de guia é código, não ilustração.** As 3 queries-modelo estão nos testes (`18.10a/b/c`) e rodam a cada suíte. Foi justamente executá-las que expôs o defeito do Dictionary (etapa 17.5) — a alternativa, copiar SQL plausível para o documento, teria publicado o guia com o defeito dentro.
- **Limite documentado precisa armar.** Os valores sugeridos (`60 s`, `50M linhas`, `4 GiB`) são de produção, mas as mensagens de erro no guia foram capturadas forçando cada limite com valor baixo contra o cluster real. Usuário que não reconhece a mensagem não sabe que bateu no limite.
- **Perfil `analytics_ro` é referenciado, não criado aqui.** Criá-lo é entrega da etapa 19; duplicar a matriz de acesso nos dois documentos garantiria divergência. O guia aponta para `SEGURANCA-E-GOVERNANCA.md`.
- **Hex documentado sem execução.** Não há conta neste ambiente e provisionar PrivateLink está fora do escopo (Seção 2). Mesmo padrão do `StorageAlto` sem `node_exporter` na etapa 15: descrever o que valeria em produção e declarar que não foi validado.

Desvios do plano:
1. **O passo 3 encontrou um defeito de produto e parou a etapa.** Medir as queries-modelo revelou que o `dict_institutions` resolvia **33,55%** do volume, com a API servindo `"desconhecida"` para 66% das instituições. Virou a **etapa 17.5**, executada e fechada antes de continuar a 18 — defeito em funcionalidade entregue não cabe como nota de rodapé de etapa documental.
2. **Três armadilhas novas descobertas escrevendo o guia**, todas por execução: `countMerge` sobre coluna `countIf` (`requires zero or one argument`), `dictGet` sem `tuple()` em chave `COMPLEX_KEY_HASHED`, e `sum(countMerge(...))` (`ILLEGAL_AGGREGATION`, mesma classe da etapa 14, reencontrada de forma independente). As três entraram na tabela de armadilhas com o erro literal — é o que se pesquisa por `Ctrl+F` quando a query quebra.
3. **O contraexemplo de poda de partição foi medido, não afirmado.** `WHERE toString(created_at) LIKE '...'` lê **6.094.848 linhas em 216 ms** contra **8.192 linhas em 6 ms** da forma correta: 36× mais lento, 744× mais dado, resposta idêntica. Um número medido convence mais que "evite funções na coluna do filtro".
4. **O trade-off de `accounts`/Q2 ganhou seção no `REPORT.md`**, além do guia. O plano previa declarar nos dois; ao escrever, ficou claro que o `REPORT.md` não tinha **nenhuma** menção à consequência (Q2 não é respondível no ClickHouse), só à decisão de schema. A limitação existia desde S01 e nunca havia sido declarada.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (bloco `# --- 18 data-champions ---`, 16 testes)
- [x] run_all.sh sem FAIL — **207 pass, 0 fail, 3 skip**
- [x] ESTADO HERDADO da próxima (19) preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → registrados em `99-validacao-final.md`
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
