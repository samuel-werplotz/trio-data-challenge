# Medições — versão ingênua (etapa 06)

Protocolo (S06 § O método): cada query roda 4 vezes; a 1ª execução é descartada
(aquece o cache do buffer pool); a **mediana das 3 execuções seguintes** é o
tempo registrado. `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` completo de cada uma
está em `explains/qN_before.txt`.

Nenhum índice, nenhum CAgg existe neste ponto — este é o "antes" honesto que
as etapas 07/08 vão otimizar e comparar.

| Query | Mediana (3 execuções) | Buffers (execução medida) | Observação |
|---|---|---|---|
| Q1 — volume/valor por tipo+status, 6 meses | 12.115 ms | shared hit=95.670, read=0 | 100% cache (dado já visitado por `ANALYZE`/execuções anteriores). ~180 chunks varridos, JIT compila plano por chunk — custo dominante é planejamento+JIT, não I/O. |
| Q2 — divergências de reconciliação, 30 dias | 1.584 ms | shared hit=157.938 read=170.126 | **Remedido na etapa 07** sobre o dado corrigido de `reconciliation_events` (ver nota abaixo). O valor original desta etapa (8.103 ms) foi medido sobre dado com dois defeitos de geração e não é comparável ao "depois". `t.created_at = r.transaction_created_at` no JOIN permite exclusão de chunk, mas sem índice o scan em `transactions` é sequencial. |
| Q3 — top 20 instituições, 90 dias | 1.285 ms | shared hit=53.407, read=0 | 100% cache. 15 instituições (baixa cardinalidade) → `HashAggregate` eficiente mesmo sem índice. |
| Q4 — duplicatas 5min, self-join (anti-padrão) | 2.814 ms | shared hit=baixo, read=499 | Mais rápida do que o esperado pelo anti-padrão de S06 — o planejador escolheu **Parallel Hash Join**, não Nested Loop ingênuo. Ainda assim é o anti-padrão: plano varre e cruza ~959k linhas em 7 dias (5x o volume de referência de S06, ~190k) sem aproveitar ordenação alguma. Comparar com a versão window function (etapa 07) deve mostrar ganho por eliminar a comparação todos-contra-todos, não necessariamente por tempo de parede nesta escala. |

## Nota — Q2 foi remedida na etapa 07

O `q2_before.txt` desta pasta é a **segunda** medição, feita na etapa 07 depois
de corrigir dois defeitos do gerador de `reconciliation_events` que invalidavam
a comparação: divergência calculada como percentual do valor (fazia 86% das
linhas divergirem, não ~8%) e `reconciled_at = now()` para todas as linhas
(fazia o filtro "últimos 30 dias" não excluir nada). Para o "antes" continuar
honesto, os índices de Q2 foram removidos, a medição refeita, e só então
recriados. Detalhe completo em `desafio-1/REPORT.md`.

## Nota de ambiente

`shm_size` do serviço `timescaledb` subido de 64 MB (default Docker) para 1 GB
no `docker-compose.yml` — o hash join de Q4 sem essa folga falhava com
`could not resize shared memory segment: No space left on device` antes mesmo
de produzir um plano para medir. Mudança de infra, sem efeito sobre schema ou
dado; os 10M de linhas foram preservados (volume não foi recriado).

## Sobre "shared hit vs read"

S06 pede sempre reportar a comparação hit/read — não que ambos sejam > 0. Q1
e Q3 leram 100% de cache (efeito natural de rodar 4x em sequência sobre o
mesmo processo Postgres); Q2 e Q4 tocaram disco porque acessam tabelas/chunks
ainda não visitados na sessão. Isso é o comportamento honesto do ambiente, não
um artefato do protocolo — reportado como está.
