# Migração do legado para Aurora — análise (documento, não executado)

## Inventário

| Item | Valor |
|---|---|
| Motor atual | PostgreSQL 16 autogerenciado (container `postgres-legado`) |
| Tabelas de negócio | `partner_institutions` (15), `institution_configs` (480), `legacy_users` (50.000), `legacy_accounts` (80.000) |
| Tamanho do banco | 86 MB (inclui ~59 MB de bloat induzido) |
| Dívidas técnicas | `SERIAL` em vez de `IDENTITY`; `TIMESTAMP` sem fuso em toda tabela; `VARCHAR(n)` com limite arbitrário; sem particionamento |
| Bloat medido | `legacy_accounts`: **83,3% de linhas mortas**, 70 MB para 80.000 linhas úteis (~6×). **Induzido de propósito** (5 rodadas de `UPDATE` sem `VACUUM`) para dar evidência real à recomendação — um banco impecável ao lado tornaria isto opinião, não argumento. |

## (a) EC2 autogerenciado × RDS × Aurora — a comparação de destino

O PDF § 3.2 B.3 pede a comparação entre as três opções, não a defesa de uma.
As três são viáveis; mudam o custo, o esforço operacional e o que se ganha.

| Critério | EC2 autogerenciado | RDS PostgreSQL | Aurora PostgreSQL |
|---|---|---|---|
| **Custo base** | Menor por hora de instância; paga-se em pessoa | Intermediário; storage provisionado | Maior por vCPU; storage por uso real |
| **Custo medido no volume atual** | ≈ **$140/mês** (`m6g.large` + EBS) | ≈ **$253/mês** (`db.m6g.large` Multi-AZ) | ≈ **$279/mês** (Serverless v2, 2–8 ACU) |
| **Custo medido no cenário 10×** | ≈ **$560/mês** + réplica manual | ≈ **$1.010/mês** (`db.m6g.2xlarge` Multi-AZ) | ≈ **$840/mês** (Serverless v2, 4–16 ACU) |
| **Custo real (TCO)** | O maior — inclui plantão, patch, tuning de backup | Médio | Menor em equipe pequena: elimina trabalho, não só servidor |
| **Escala de leitura** | Réplica manual (streaming), promoção manual | Até 5 réplicas, lag de segundos | Até 15 réplicas, **lag < 100 ms**, reader endpoint único |
| **HA / RTO** | Patroni ou script próprio; RTO em minutos | Multi-AZ com failover automático; RTO 1–2 min | Failover **< 30 s**; storage já replicado em 3 AZs |
| **Durabilidade** | EBS + backup que você opera | Snapshot + PITR gerenciados | **6 cópias em 3 AZs**, PITR nativo por segundo |
| **Overhead operacional** | Alto: patch, vacuum, backup, monitoramento, failover | Baixo | Baixo, com storage que não exige dimensionamento prévio |
| **Elasticidade** | Redimensionar = downtime | Redimensionar = failover | Serverless v2 escala sem downtime |
| **Trava de fornecedor** | Nenhuma | Baixa (PostgreSQL puro) | **Média** — storage é proprietário; sair exige dump/restore |
| **Bloat** | `autovacuum` tunado à mão | Mesmo mecanismo | **Mesmo mecanismo** — Aurora *não* resolve bloat |

> **Base dos valores**: preço de tabela pública `us-east-1`, agosto de 2026, sem
> Savings Plans nem Reserved Instances. Premissas de dimensionamento linha a
> linha em [`docs/CUSTO-AWS.md`](../docs/CUSTO-AWS.md). Estimativa de ordem de
> grandeza para decisão de orçamento — não é cotação.

**A inversão de custo entre os dois cenários é o dado que mais importa aqui.**
No volume atual o Aurora custa **+$26/mês (+10%)** sobre o RDS; no cenário de
10× ele custa **−$170/mês (−17%)**. O motivo é o Serverless v2: ele escala para
baixo em horário ocioso, enquanto o RDS Multi-AZ provisiona para o pico 24/7.
A afirmação genérica de que "Aurora custa 20–30% a mais" é verdadeira por vCPU
e falsa como conta mensal — depende inteiramente do perfil de carga.

**Recomendação: Aurora PostgreSQL**, com uma ressalva honesta.

*Por quê:* o legado é a origem do `ref-sync`, e o **reader endpoint** é o ganho
concreto — hoje toda leitura cai no mesmo nó que atende escrita. O failover
automático importa mais aqui do que em qualquer outro componente: é instância
única, sem réplica, e um pagamento não espera failover manual.

*A ressalva:* **86 MB de banco não justificam Aurora por performance nem por
preço.** Se a decisão fosse só sobre este volume, RDS Multi-AZ entregaria o
mesmo por **$26/mês a menos** e sem trava de storage. A justificativa é de
**trajetória** — o legado cresce e é fonte de sistema de pagamento — não do
estado atual. Vender Aurora como ganho de performance para 86 MB seria
enganoso; vendê-lo como economia hoje seria falso. A economia aparece no
cenário 10×, e é lá que a recomendação se paga.

Para o **legado especificamente**, o custo é quase irrelevante na decisão: são
≈ **$44/mês** em Serverless v2 com 0,5 ACU média, porque o banco fica ocioso a
maior parte do tempo. O que se compra por esse valor é failover automático numa
instância que hoje é única — não capacidade.

**Quando RDS seria a escolha certa:** se o banco permanecer pequeno e estável,
se houver exigência de portabilidade entre nuvens, ou se o time já opera RDS e
não tem apetite para mais um motor.

## (b) Estratégia de migração — três caminhos, um escolhido

| Estratégia | Downtime | Complexidade | Quando usar |
|---|---|---|---|
| **`pg_dump`/`restore`** | Minutos a horas | Baixa | Banco pequeno e janela de manutenção aceita |
| **DMS com CDC** | Segundos | Média | Downtime precisa ser mínimo; heterogeneidade |
| **Replicação lógica nativa** | Segundos | Média | PostgreSQL → PostgreSQL, mesma versão maior |
| **Blue-green (RDS)** | < 1 min | Baixa (gerenciada) | AWS gerencia a réplica e o switchover |

**Escolhido: replicação lógica nativa**, com `pg_dump` como plano B.

*Por quê nativa e não DMS:* origem e destino são ambos PostgreSQL 16. O DMS
existe para heterogeneidade (Oracle→Postgres) e cobra por isso em complexidade
— tarefa, endpoints, instância de replicação, mapeamento de tipos. Para
homogêneo, a replicação lógica é o caminho mais curto e usa o mecanismo do
próprio banco.

*Por quê `pg_dump` é plano B viável e não fallback vergonhoso:* **86 MB**
restauram em minutos. Se a replicação lógica der problema, a janela de
manutenção noturna é suficiente — e este é o argumento mais forte a favor de
migrar cedo, enquanto o banco ainda é pequeno.

**Passos do cutover:**

1. **Provisionar** Aurora PostgreSQL 16, Multi-AZ, na mesma VPC.
2. **Preparar o schema** — só DDL, sem dado:
   ```bash
   pg_dump --schema-only -h postgres-legado -U trio trio_legado | psql -h <aurora> -U trio trio_legado
   ```
3. **Publicação na origem / assinatura no destino:**
   ```sql
   -- origem
   CREATE PUBLICATION pub_legado FOR ALL TABLES;
   -- destino
   CREATE SUBSCRIPTION sub_legado
     CONNECTION 'host=postgres-legado dbname=trio_legado user=trio'
     PUBLICATION pub_legado;   -- copia inicial + streaming contínuo
   ```
4. **Validar** — contagem por tabela **e** checksum de valor, não só linhas:
   ```sql
   SELECT 'legacy_accounts' AS t, count(*), sum(balance) FROM legacy_accounts
   UNION ALL SELECT 'legacy_users', count(*), NULL FROM legacy_users
   UNION ALL SELECT 'partner_institutions', count(*), NULL FROM partner_institutions
   UNION ALL SELECT 'institution_configs', count(*), NULL FROM institution_configs;
   ```
   Contagem igual com soma diferente denuncia corrupção de tipo — o erro que
   passa despercebido quando só se contam linhas.
5. **Aguardar o lag zerar:**
   ```sql
   SELECT slot_name, active,
          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag
     FROM pg_replication_slots;
   ```
6. **Corte:** aplicação em read-only → lag a zero → repontar string de conexão
   (**apontando leitura para o reader endpoint**) → retomar escrita.
7. **`ANALYZE` no destino** — estatísticas **não** vêm pela replicação, e sem
   isso o Aurora começa com o mesmo problema de estimativa medido abaixo:
   ```sql
   ANALYZE VERBOSE;
   ```

## (c) Riscos e mitigações

| # | Risco | Prob. | Impacto | Mitigação |
|---|---|---|---|---|
| 1 | **Estatísticas não migram** → planner erra do lado novo | **Alta** | Médio | `ANALYZE` obrigatório no cutover (passo 7). É o risco medido neste próprio documento: 509.298 × 80.000 linhas |
| 2 | **Bloat vai junto** — replicação copia dado lógico, não físico | **Alta** | Baixo | Aceitar (a cópia inicial já chega sem bloat) ou `VACUUM FULL` antes; Aurora não resolve bloat sozinho |
| 3 | **`SERIAL` dessincroniza** — sequências não avançam pela replicação lógica | **Alta** | **Crítico** | `setval()` em toda sequência antes de liberar escrita. Esquecer = violação de PK na primeira inserção |
| 4 | Slot de replicação órfão enche o WAL da origem | Média | Alto | Alerta de tamanho do slot; `DROP SUBSCRIPTION` remove o slot ao final |
| 5 | `TIMESTAMP` sem fuso interpretado de forma diferente | Média | Alto | `timezone` idêntico nos dois; a dívida real é projeto à parte |
| 6 | Aplicação com string de conexão fixa em código | Média | Médio | Endpoint por variável/Secrets Manager antes de migrar |
| 7 | Custo acima do previsto (Serverless v2 escalando) | Média | Médio | Teto de ACU + alarme de billing na 1ª semana |
| 8 | Ref-sync apontado para o writer por engano | Baixa | Médio | Apontar para o **reader**; é o ganho que a migração habilita |

**O risco nº 3 é o que mais derruba migração de PostgreSQL** e o menos citado:
a replicação lógica copia linhas, não o estado das sequências. O destino fica
com todo o dado e `nextval()` em 1.

```sql
-- Antes de liberar escrita, para CADA sequência:
SELECT setval('legacy_accounts_id_seq', (SELECT max(id) FROM legacy_accounts));
SELECT setval('legacy_users_id_seq',    (SELECT max(id) FROM legacy_users));
SELECT setval('partner_institutions_id_seq', (SELECT max(id) FROM partner_institutions));
SELECT setval('institution_configs_id_seq',  (SELECT max(id) FROM institution_configs));
```

> Este projeto já esbarrou nesta classe de erro: na etapa 10, o seed assumia
> `id` contíguo a partir de 1, e `SERIAL` **não é transacional** — um rollback
> deixou buracos e quebrou a FK. A lição vale igual no cutover.

## (d) Plano de rollback

**Critério de aborto, decidido antes do corte** — sem isso a decisão vira
discussão sob pressão:

| Sintoma | Ação |
|---|---|
| Divergência de contagem ou checksum | **Aborta**, não corta |
| Lag não zera em 15 min | **Aborta**, reagenda |
| Erro de aplicação após o corte | Rollback imediato (abaixo) |
| Latência > 2× a linha de base | Rollback se não normalizar em 30 min |

**Janela de reversão: 72 h.** O legado fica **de pé e intacto**, em read-only,
durante todo o período. Rollback é repontar a string de conexão de volta.

```
T+0h   Corte. Legado read-only, NÃO desligado.
T+0-2h Validação intensiva: contagem, checksum, latência, erro de aplicação.
T+2h   Replicação reversa (Aurora → legado) para não perder o que foi escrito
       depois do corte. É o que torna o rollback real em vez de teórico.
T+72h  Sem incidente → legado desativado (snapshot final antes).
```

**Rollback dentro das primeiras 2 h** (antes da replicação reversa): repontar
a aplicação para o legado. Nada foi perdido — ele estava read-only, e o que
entrou no Aurora precisa ser reaplicado à mão (volume pequeno nesse intervalo).

**Rollback entre 2 h e 72 h:** a replicação reversa já mantém o legado
atualizado. Repontar e promover para read-write.

**Depois de 72 h** não há rollback — há **migração de volta**, com o mesmo
procedimento em sentido inverso. Por isso a janela é explícita: chamar de
"rollback" algo que exige uma migração completa é enganar a si mesmo no
planejamento.

## Custo, performance, HA — resumo

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
