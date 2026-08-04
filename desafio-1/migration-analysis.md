# Migração do legado para Aurora — análise (documento, não executado)

## Inventário

| Item | Valor |
|---|---|
| Motor atual | PostgreSQL 16 autogerenciado (container `postgres-legado`) |
| Tabelas de negócio | `partner_institutions` (15), `institution_configs` (480), `legacy_users` (50.000), `legacy_accounts` (80.000) |
| Tamanho do banco | 86 MB (inclui ~59 MB de bloat induzido) |
| Dívidas técnicas | `SERIAL` em vez de `IDENTITY`; `TIMESTAMP` sem fuso em toda tabela; `VARCHAR(n)` com limite arbitrário; sem particionamento |
| Bloat medido | `legacy_accounts`: **83,3% de linhas mortas**, 70 MB para 80.000 linhas úteis (~6×). **Induzido de propósito** (5 rodadas de `UPDATE` sem `VACUUM`) para dar evidência real à recomendação — um banco impecável ao lado tornaria isto opinião, não argumento. |

## Estratégia de cutover

1. **Provisionar Aurora PostgreSQL** (engine-compatible) em Multi-AZ.
2. **Carga full via DMS/`pg_dump`** — 86 MB, minutos.
3. **CDC do DMS** (não o Debezium do pipeline TimescaleDB→ClickHouse) mantendo Aurora sincronizado durante a validação.
4. **Validação**: contagem por tabela + checksum (`sum(balance)`, mesmo princípio do exercício de recuperação de S07 Parte 3).
5. **Corte**: pausar escritas no legado → lag do DMS a zero → repontar aplicação → retomar escritas.
6. **Rollback**: legado read-only por 72h com replicação reversa, caso o corte precise desfazer.

## Custo, performance, HA

| Critério | Atual (autogerenciado) | Aurora PostgreSQL |
|---|---|---|
| Custo | Capacidade fixa 24/7 | Serverless v2 escala com carga; storage por uso real |
| Performance | Storage local/EBS; réplica manual | Storage distribuído (6 cópias/3 AZs); até 15 réplicas, lag <100ms |
| HA | Failover manual/Patroni; RTO em minutos | Failover automático; RTO tipicamente <30s |
| Operação | Patch/backup/monitoramento manuais | Gerenciados; backup contínuo (PITR nativo) |
| Bloat | `autovacuum` tunado manualmente | Mesmo mecanismo — Aurora não elimina bloat, simplifica o resto |

## O que muda (e o que não muda)

Aurora troca **infraestrutura**, não **modelo de dados**: `SERIAL`/`TIMESTAMP`
sem fuso continuam existindo até uma migração de schema deliberada — a dívida
real (fuso horário em sistema de pagamento multi-fuso) é projeto à parte. SQL,
índices e queries são PostgreSQL-compatíveis e não mudam. O que muda é a
economia de I/O (storage distribuído via rede, não disco local — vale remedir
plano após migrar) e o backup, que sai de `pgBackRest` operado (S07 Parte 2)
para gerenciado.

## As 2 queries complexas — antes/depois

Protocolo de S06/S07 (4 execuções, 1ª descartada, mediana das 3 seguintes).
"Antes" = bloat presente, **sem `ANALYZE`** desde a criação; "depois" = mesmo
bloat físico, só estatísticas atualizadas (nenhum `VACUUM` rodou entre as
duas medições — isolando o efeito de estimativa, não de espaço).

| Query | Antes | Depois | O que mudou de fato |
|---|---|---|---|
| Legacy Q1 — contas por instituição | 166,5 ms | 183,3 ms (ruído) | Estimativa do `Seq Scan` em `legacy_accounts`: **509.298 → 80.000** linhas (exata). O planner via a tabela 6,4× maior por contar linha morta como viva. |
| Legacy Q2 — configuração vigente | 0,20 ms | 0,17 ms | Dataset pequeno (480 linhas) — qualquer plano é instantâneo |

Tempo de Q1 não mudou porque o planner já escolhia `Hash Join` mesmo com a
estimativa errada — volume baixo demais para virar `Nested Loop` (o pior caso
de S07). Em produção, com tabelas maiores, é exatamente esse tipo de erro de
estimativa que empurra o planner para `Nested Loop` sobre milhões de linhas.
Reportar o resultado real — sem ganho de tempo, com ganho de estimativa — é
mais honesto que forçar a narrativa esperada. Arquivos completos:
`desafio-1/queries/explains/legacy_q{1,2}_{before,after}.txt`.
