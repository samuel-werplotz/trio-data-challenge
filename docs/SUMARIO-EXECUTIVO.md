# Sumário executivo

[← Voltar ao README](../README.md)

Plataforma de dados para infraestrutura de pagamentos, construída e medida em
ambiente reproduzível: **10 milhões de transações** em 12 meses no TimescaleDB
transacional, replicadas para ClickHouse analítico por um pipeline próprio, com
observabilidade, backup testado e procedimentos de operação escritos.

Sobe com **um comando** (`docker compose up -d`) e se verifica com outro
(`bash scripts/tests/run_all.sh` — 171 testes). Detalhe técnico em
[`desafio-1/REPORT.md`](../desafio-1/REPORT.md) e
[`desafio-2/ADR.md`](../desafio-2/ADR.md).

## Os 5 números

| | Resultado | O que significa |
|---|---|---|
| **Query analítica** | 12.115 ms → **23 ms** (521×) | O relatório que travava o banco virou consulta interativa |
| **Compressão** | **5,0×** (23,5× só na tabela) | 2.674 MB → 536 MB; menos storage e menos I/O por consulta |
| **Freshness do pipeline** | **~10 s** (alvo < 30 s) | O painel mostra o agora, não o de ontem |
| **RTO / RPO medidos** | **22 s / 60 s** | Restore executado de verdade, com perda simulada — não é promessa |
| **Custo estimado em produção** | **≈ US$ 844/mês** | Volume atual; ≈ US$ 2.700 no cenário de 10× ([detalhe](CUSTO-AWS.md)) |

O custo por milhão de transações **cai de $84 para $27** ao decuplicar o volume:
a arquitetura agrega na ingestão, então o gasto acompanha o que entra, não o
acumulado.

## Os 3 riscos

| Risco | Impacto se materializar | Dono | Mitigação e prazo |
|---|---|---|---|
| **ClickHouse é nó único, sem réplica** | Perda do motor analítico até reconstruir (~1 min de backfill, mas dashboards e Data Champions param) | Eng. de Dados | **Já resolvido em configuração**: `docker-compose.ha.yml` sobe 3 Keepers + 2 réplicas e `scripts/tests/ha-smoke.sh` comprova failover real (11/11). Falta só promovê-lo a padrão em produção — **60 dias** |
| **Pipeline sem teste de saturação** | Freshness de 10 s foi medida em regime ocioso; sob pico real o lag é desconhecido | Eng. de Dados | Teste de carga em patamares até 5.800 escritas/s, com o ponto de saturação documentado — **30 dias** |
| **Sem trilha de auditoria de leitura de PII** | Numa fiscalização, não há como responder quem consultou dados de titular | Segurança / Dados | Log de acesso a `accounts` + matriz de perfis por tabela, mapeada à Res. BCB 4.658 — **30 dias** |

Os três são **conhecidos e declarados**, não descobertos. Nenhum bloqueia a
operação no volume atual; todos bloqueiam a escala ou a auditoria regulatória.

## Roadmap 30 / 60 / 90

**30 dias — fechar a exposição regulatória e conhecer o limite**
Perfis de acesso por tabela e auditoria de leitura de PII no ar. Segredos fora
do código, em Secrets Manager com rotação. Teste de saturação executado, com o
patamar de quebra documentado. Guia do Data Champion publicado, com limites de
custo de query aplicados no servidor.

**60 dias — resiliência**
ClickHouse replicado promovido a padrão — a topologia já existe e foi
comprovada (`docker-compose.ha.yml` + `ha-smoke.sh`, 11/11 incluindo failover);
falta a migração das tabelas pelo procedimento de tabela sombra +
`EXCHANGE TABLES`. Legado migrado para Aurora (plano de 72 h já escrito, com
critério de aborto e janela de rollback de 72 h). Drill de restore semanal
automatizado, com alarme se o RTO passar de 5 minutos.

**90 dias — escala e autonomia**
Sharding do ClickHouse por faixa de instituição e particionamento do
sync-worker, na ordem dos 4 movimentos do ADR — **fila (MSK) fica por último**,
e só se os três anteriores não bastarem: ela custa ≈ US$ 620/mês, 73% do custo
atual da plataforma inteira. Data Champions operando por conta própria, com o
catálogo de dados e o acesso via Hex estabelecidos.

## A decisão que mais define esta plataforma

**Micro-batch por watermark, não CDC.** O Debezium foi construído, medido e
descartado: `publish_via_partition_root` não funciona sobre hypertable — causa
provada, não suposta, com o experimento preservado no repositório. A alternativa
entrega os mesmos 10 s de freshness, é idempotente por construção
(`ReplacingMergeTree` versionado) e **evita US$ 620/mês** em fila gerenciada.

O mesmo padrão vale para o resto da entrega: onde algo não foi feito, está
escrito o porquê e o que seria preciso — incluindo os casos em que a medição
contrariou a expectativa e o resultado foi reportado assim mesmo.
