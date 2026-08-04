# Resposta a incidente — SEV-1: dashboards de Pix zerados há 2 horas

> **CENÁRIO (PDF § 5.2 C).** 06h47. Dashboards de Pix mostram volume **ZERO**
> nas últimas 2h. Aplicações retornam dados desatualizados. Transações estão
> sendo processadas normalmente no TimescaleDB.
>
> **Contexto:** na noite anterior houve **manutenção de compressão no
> TimescaleDB** *e* **atualização de security group na VPC**.

| | |
|---|---|
| **Severidade** | SEV-1 |
| **Impacto** | Visibilidade, **não** operação. Pagamentos seguem sendo processados |
| **Alerta que deveria ter disparado** | `PipelineParado` — teria detectado em **5 min**, não em 2h |

> **O enunciado dá DUAS pistas de propósito** — manutenção *e* security group.
> Uma árvore de hipóteses que ignora qualquer uma delas está incompleta. As duas
> aparecem no topo da tabela abaixo, e as duas são verificáveis em < 1 min.

---

## 1. Linha de investigação — os primeiros 5 minutos

O método é **bissecção**: cada passo elimina metade das hipóteses. Não é sorte,
é ordem — e é isso que separa 5 minutos de 2 horas.

### Passo 1 — É o pipeline ou é a leitura?

```sql
-- No ClickHouse (destino):
SELECT max(created_at) AS ultimo_dado,
       dateDiff('minute', max(created_at), now()) AS minutos_atras
  FROM trio_analytics.transactions_raw;
```

| Resultado | Leitura |
|---|---|
| Velho (2h+) | **O pipeline parou.** Siga para o passo 2 |
| Fresco (< 1 min) | O dado chegou: o problema é de **leitura/dashboard**. Vá para a hipótese 6 |

> Este passo sozinho corta o espaço de busca ao meio. Faça-o **primeiro**,
> sempre — antes de olhar log de qualquer serviço.

### Passo 2 — Há quanto tempo o worker não grava?

```bash
curl -s localhost:8001/metrics | grep -E "sync_last_success_timestamp|sync_lag_seconds"
```

`sync_last_success_timestamp` parado há ~2h **com** `sync_lag_seconds` alto
confirma: o worker não está conseguindo completar ciclo.

### Passo 3 — O worker está vivo? Qual é o erro?

```bash
docker ps --filter name=trio-sync-worker --format "{{.Status}}"
docker logs trio-sync-worker --tail 50
```

O que o log distingue de imediato:

| Sintoma no log | Aponta para |
|---|---|
| `timeout` / `connection refused` na **origem** | Hipóteses 1 e 2 |
| `connection refused` no **ClickHouse** | Hipótese 4 |
| Nenhuma linha nova (silêncio total) | Hipótese 3 — processo travado, não morto |
| `lock` / `canceling statement` | Hipótese 5 |

### Passo 4 — A origem responde? Em quanto tempo?

```bash
# Do container do worker, não do host: é a rota dele que interessa.
docker exec trio-sync-worker python -c "
import time, psycopg
t=time.time()
with psycopg.connect(host='timescaledb', user='trio', password='trio2024',
                     dbname='trio_transactions', connect_timeout=5) as c:
    print('conectou em %.2fs' % (time.time()-t))
    print(c.execute('SELECT max(updated_at) FROM transactions').fetchone())
"
```

Falha de conexão daqui, com o banco saudável pelo lado do host, é a **assinatura
de bloqueio de rede** — hipótese 2.

### Passo 5 — Há bloqueio no banco?

```sql
SELECT pid, state, wait_event_type, wait_event,
       now() - query_start AS duracao, left(query, 80)
  FROM pg_stat_activity
 WHERE state <> 'idle' AND now() - query_start > INTERVAL '1 minute'
 ORDER BY duracao DESC;
```

### O que consultar na AWS (produção)

| Fonte | O que responde |
|---|---|
| **VPC Flow Logs** | `REJECT` entre a subnet da aplicação e a do banco — prova objetiva de bloqueio por security group |
| **CloudWatch Logs** (`/ecs/sync-worker`) | O mesmo log do passo 3, com retenção |
| **CloudWatch Metrics** — `DatabaseConnections`, `CPUUtilization` (RDS/Aurora) | Se a origem estava saturada durante a manutenção |
| **CloudWatch Metrics** — `Trio/Pipeline/SecondsSinceLastSuccess` | Quando exatamente parou — o horário delimita a causa |
| **ECS Service Events** | Task morta, reiniciada, ou com deployment travado |
| **CloudTrail** | **Quem** alterou o security group, quando e o quê. É o que liga a mudança ao incidente |

---

## 2. Árvore de hipóteses

Ordenadas por probabilidade. As duas primeiras correspondem às duas pistas do
enunciado.

### Hipótese 1 — Manutenção de compressão derrubou/travou a leitura do worker — **ALTA**

**Por quê:** a manutenção de compressão é longa e pesada. `compress_chunk()`
toma `AccessExclusiveLock` no chunk; o `SELECT` incremental do worker fica em
espera, estoura o `statement_timeout` e o ciclo falha. Repetidamente, sem que
nada apareça de errado do lado da aplicação — **origem saudável, destino
congelado**, exatamente o sintoma descrito.

**Verificar em 1 min:**
```sql
SELECT pid, state, wait_event, now() - query_start AS duracao, left(query,60)
  FROM pg_stat_activity WHERE state <> 'idle' ORDER BY duracao DESC LIMIT 5;

SELECT job_id, last_run_status, last_run_started_at, total_failures
  FROM timescaledb_information.job_stats WHERE job_id >= 1000;
```

**Confirma se:** houver job de compressão ainda rodando ou com falha, ou
`wait_event` de lock na janela do incidente.

> **Nota sobre o desenho atual.** Na arquitetura original (CDC/Debezium), a
> hipótese nº 1 seria *"o slot de replicação ficou órfão"* — o PostgreSQL
> acumularia WAL indefinidamente esperando um consumidor que não volta, e o
> incidente de visibilidade viraria **incidente de indisponibilidade** por disco
> cheio. Esse risco **não existe aqui**: o micro-batch por watermark não usa slot
> de replicação. É uma classe inteira de falha que a decisão de arquitetura
> eliminou — e vale dizer isso no post-mortem, não só no ADR.

### Hipótese 2 — Security group bloqueou a rota do worker até o banco — **ALTA**

**Por quê:** é a segunda pista do enunciado, e o sintoma bate perfeitamente. Se
a regra que permitia a saída do worker para a porta 5432 (ou para o ClickHouse)
foi removida, ele deixa de conectar **sem que nada mude no banco** — que segue
recebendo transações normalmente pelas outras rotas.

**Verificar em 1 min:**
```bash
# Do worker, testando cada destino
docker exec trio-sync-worker sh -c "nc -zv timescaledb 5432; nc -zv clickhouse 8123"
```
```
# Em produção:
aws ec2 describe-security-groups --group-ids sg-XXXX
aws logs filter-log-events --log-group-name /aws/vpc/flowlogs \
  --filter-pattern "REJECT" --start-time <epoch_da_noite>
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=RevokeSecurityGroupEgress
```

**Confirma se:** houver `REJECT` nos Flow Logs, ou o CloudTrail mostrar
`Revoke*`/`Authorize*` na janela da manutenção.

### Hipótese 3 — Processo do worker travado (vivo, mas sem progredir) — **MÉDIA**

**Por quê:** o container aparece `Up` e o healthcheck passa, mas o laço está
preso numa chamada de rede sem timeout. Pior que morrer: `docker ps` mente.

**Verificar:**
```bash
docker ps --filter name=trio-sync-worker --format "{{.Status}}"
docker logs trio-sync-worker --tail 20     # silêncio total = travado
curl -s localhost:8001/metrics | grep sync_cycles_total
```
**Confirma se:** o contador de ciclos não avança entre duas leituras espaçadas.

### Hipótese 4 — ClickHouse recusando escrita — **MÉDIA**

**Por quê:** disco cheio, `too many parts` ou serviço fora. O worker lê bem, mas
não consegue gravar; o watermark não avança e o destino congela.

**Verificar:**
```bash
docker exec trio-clickhouse df -h /var/lib/clickhouse
docker exec trio-clickhouse clickhouse-client -q "SELECT table, count() AS partes FROM system.parts WHERE active GROUP BY table ORDER BY partes DESC LIMIT 5"
docker logs trio-clickhouse --tail 50 | grep -iE "error|exception|readonly"
```
**Confirma se:** houver `TOO_MANY_PARTS`, disco > 95% ou exceção de escrita.

### Hipótese 5 — Contenção de lock por outra operação — **BAIXA**

**Por quê:** um `VACUUM FULL`, `REINDEX` ou migração deixada rodando após a
janela bloqueia a leitura do worker. Distinto da hipótese 1 por não ser o job
de compressão do TimescaleDB.

**Verificar:**
```sql
SELECT blocked.pid AS bloqueado, blocking.pid AS bloqueador,
       left(blocking.query, 60) AS query_bloqueadora
  FROM pg_stat_activity blocked
  JOIN pg_stat_activity blocking
    ON blocking.pid = ANY(pg_blocking_pids(blocked.pid))
 WHERE blocked.wait_event_type = 'Lock';
```

### Hipótese 6 — O dado chegou, mas o dashboard não o mostra — **BAIXA**

**Por quê:** só sobrevive se o passo 1 mostrou dado **fresco** no ClickHouse.
Aí a falha é de leitura: datasource com credencial expirada, painel com janela
de tempo errada, ou cache da API servindo resposta velha.

**Verificar:**
```bash
curl -s localhost:8000/health
curl -s "localhost:8000/ops/volume-now" | head -c 200
curl -s -u admin:admin localhost:3000/api/health
```

### Hipótese 7 — Watermark corrompido/avançado demais — **BAIXA**

**Por quê:** se o watermark foi para o futuro (relógio, restore de estado
errado), o worker consulta uma janela vazia, "conclui com sucesso" e nunca mais
grava. É a hipótese mais traiçoeira: **tudo parece saudável**, sem erro nenhum.

**Verificar:**
```bash
curl -s localhost:8001/metrics | grep sync_watermark_timestamp
```
```sql
SELECT * FROM sync_state;   -- comparar com max(updated_at) real
SELECT max(updated_at) FROM transactions;
```
**Confirma se:** o watermark estiver ≥ `max(updated_at)` da origem, com
`sync_last_success_timestamp` recente e zero linhas gravadas.

---

## 3. Resolução da hipótese mais provável (nº 1)

**Diagnóstico confirmado:** job de compressão segurando lock; ciclos do worker
falhando por timeout desde ~04h45.

```sql
-- 1. Confirmar e liberar. Cancelar (não matar) primeiro: o cancel encerra a
--    query mantendo a conexão e é reversível; pg_terminate_backend derruba a
--    sessão inteira.
SELECT pg_cancel_backend(pid)
  FROM pg_stat_activity
 WHERE query ILIKE '%compress_chunk%' AND state = 'active';
```

```sql
-- 2. Se a política de compressão estiver reincidindo, pausá-la até a janela
--    apropriada (é reversível, e é o job que se desabilita — não a compressão
--    já aplicada).
SELECT alter_job(1002, scheduled => false);
```

```bash
# 3. Destravar o worker. Ele retoma do watermark persistido — não é preciso
#    dizer de onde recomeçar.
docker restart trio-sync-worker
```

```bash
# 4. Acompanhar a recuperação até o lag normalizar (< 30s).
watch -n 5 'curl -s localhost:8001/metrics | grep -E "sync_lag_seconds|sync_rows_written_total"'
```

```sql
-- 5. Conferir que as 2h foram recuperadas ÍNTEGRAS, sem duplicata.
SELECT count() AS total, count(DISTINCT external_id) AS unicos
  FROM trio_analytics.transactions_raw
 WHERE created_at >= now() - INTERVAL 3 HOUR;
```

**Por que reprocessar é seguro:** `transactions_raw` é
`ReplacingMergeTree(_version)` com `_version = updated_at` em ms. Reler a mesma
janela não duplica — a versão maior vence. Foi testado: reprocessar do zero
manteve `count() FINAL` idêntico. **É a idempotência que torna a recuperação
trivial**; sem ela, cada retentativa seria uma decisão de risco.

**Reativar a política** após a normalização, com janela que não colida com o
horário de pico:

```sql
SELECT alter_job(1002, scheduled => true);
```

---

## 4. Ações pós-incidente

> O PDF pede **preventivas, não apenas detectivas**. A distinção importa:
> alerta melhor descobre mais rápido — **o incidente ainda acontece**.
> Preventivo é o que faz não acontecer.

| # | Ação | Tipo | Prazo |
|---|---|---|---|
| 1 | Alerta `PipelineParado` (§ nº 1 de [alertas.md](grafana/alertas.md)) | **Detectivo** — 5 min em vez de 2h | Feito nesta etapa |
| 2 | Alerta `AlvoDeColetaFora` — protege o próprio alerta nº 1 | **Detectivo** | Feito nesta etapa |
| 3 | **Checklist pós-manutenção**: nenhuma janela encerra sem validar que `sync_last_success_timestamp` avançou e o lag voltou a < 30s | **Preventivo** | D+2 |
| 4 | **`statement_timeout` no worker + retry com backoff** para que lock transitório não derrube o ciclo | **Preventivo** | Já implementado |
| 5 | **Compressão fora do horário de pico**, com janela que não concorre com o ciclo do worker | **Preventivo** | D+7 |
| 6 | **Mudança de security group exige revisão de impacto em pipeline** — checklist de PR de infra listando o que atravessa aquela regra | **Preventivo** | D+7 |
| 7 | **Healthcheck que mede progresso, não só processo vivo**: `Up` com o laço travado (hipótese 3) hoje passa no healthcheck | **Preventivo** | D+14 |
| 8 | Reinício automático via Lambda quando o alerta nº 1 dispara, com escalonamento se reincidir | Preventivo/remediação | D+14 |

**As três que mais importam são a 3, a 6 e a 7** — e nenhuma delas é um alerta.
As duas causas prováveis deste incidente vieram de **mudanças planejadas**
(manutenção e security group) que ninguém validou contra o pipeline ao encerrar.
Um checklist de 2 minutos ao fim da janela teria evitado as 2 horas.

---

## 5. Comunicação

### Durante

| Momento | Público | Mensagem |
|---|---|---|
| **T+5min** | `#incidentes` | "Investigando ausência de dados nos dashboards de Pix desde ~04h45. **As transações NÃO foram afetadas** — o processamento segue normal. Trata-se de atraso na camada analítica." |
| **T+15min** | Comercial e financeiro | "Causa identificada: o pipeline analítico parou de gravar após a manutenção da madrugada. **Nenhuma transação foi perdida ou deixou de ser processada.** Os dados serão recuperados integralmente. Previsão: 30 min." |
| **T+30min** | `#incidentes` | "Pipeline retomado, reprocessando a janela acumulada. Lag caindo." |
| **T+45min** | Todos | "Normalizado. As 2h de dados foram recuperadas integralmente, sem duplicidade. Dashboards atualizados." |

> **O ponto mais importante da comunicação:** dizer **logo na primeira
> mensagem** que as transações não foram afetadas. O time comercial vê "volume
> zero" e conclui que a empresa parou de faturar. Esclarecer que é problema de
> **visibilidade, não de operação**, muda completamente o nível de pânico — e é
> a diferença entre um incidente técnico e uma crise organizacional.

### Depois — post-mortem em D+1

**Blameless.** O objetivo é a causa sistêmica, não quem executou a manutenção.

Estrutura:

1. **Linha do tempo** — 04h45 (parada real) · 06h47 (detecção humana) · 07h32
   (normalização). **1h02 sem detecção** é o número que importa.
2. **Causa raiz** — não "a compressão travou o worker", e sim *"não havia
   validação do pipeline ao encerrar a janela de manutenção, e não havia alerta
   sobre ausência de gravação"*. Duas falhas independentes, ambas sistêmicas.
3. **Impacto** — 2h de atraso analítico. **Zero** transação afetada. Zero perda
   de dado.
4. **Ações** com dono e prazo (tabela da Seção 4).
5. **O que funcionou** — a idempotência do `ReplacingMergeTree` tornou a
   recuperação trivial e sem risco de duplicidade. Post-mortem que só lista
   falhas não ensina o que preservar.
