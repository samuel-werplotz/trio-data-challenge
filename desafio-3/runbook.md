# Runbook — Storage em 92%: sanitizar e remover chunks antigos sem downtime

[← Voltar ao README](../README.md)

> **CENÁRIO (PDF § 5.2 A.3).** Timescale Cloud com storage em 92%. Chunks
> comprimidos de 6+ meses precisam ser sanitizados e removidos **sem downtime**
> e **sem perder dados agregados nos continuous aggregates**.

| | |
|---|---|
| **Severidade** | SEV-2 · escala para SEV-1 se passar de 95% |
| **Duração estimada** | 2–4h (≈1–2 min por chunk, com checkpoints) |
| **Reversível?** | Sanitização **não**. Por isso a Seção 1 é obrigatória |
| **Alerta que dispara** | `StorageAlto` (> 85%) — ver [`grafana/alertas.md`](grafana/alertas.md) |

**Números reais deste ambiente** (medidos, não estimados):

| Item | Valor |
|---|---|
| Chunks totais em `transactions` | 338 (1 dia cada) |
| Chunks com 6+ meses (candidatos) | **156** |
| Espaço que ocupam | **1.111 MB** |
| Compressão vigente | 5,5× no total |

---

## Por que este procedimento é delicado

Três armadilhas, e as três já custaram post-mortem em algum lugar:

1. **Apagar chunk bruto pode furar o continuous aggregate.** Se o CAgg ainda não
   materializou aquele período, o buraco é **permanente e irrecuperável** — o
   agregado não tem de onde recalcular.
2. **Chunk comprimido resiste a alteração.** Sanitizar exige descomprimir antes,
   e descomprimir **precisa de espaço livre** — que é justamente o que falta a
   92%. É a armadilha circular do cenário.
3. **Sem downtime** significa que a operação continua escrevendo o tempo todo.
   Nada de `LOCK TABLE`, nada de janela exclusiva.

> **A ORDEM CORRETA, e ela não é negociável:**
> **primeiro** confirme que o CAgg materializou; **depois** apague o bruto.
> Inverter é irreversível — e é o erro que mais aparece em post-mortem real.

---

## 1. Pré-requisitos e validações

**Nada abaixo é opcional.** A sanitização não tem `undo`.

### 1.1 Backup recente e verificado

```bash
# Backup existe e está íntegro? (não basta existir — 'info' valida o repositório)
docker exec -u postgres trio-timescaledb pgbackrest --stanza=timescale info

# Se o último full for anterior à última manutenção, tirar um novo antes:
docker exec -u postgres trio-timescaledb pgbackrest --stanza=timescale --type=full backup
```

**Critério de aborto:** sem backup full válido posterior à última alteração de
schema, **não comece**. O procedimento não é reversível sem ele.

### 1.2 Espaço livre real

```bash
docker exec trio-timescaledb df -h /var/lib/postgresql/data
```

```sql
-- Quanto o maior chunk candidato ocupa DESCOMPRIMIDO. É esse o pico
-- transitório que a descompressão vai exigir.
SELECT pg_size_pretty(max(before_compression_total_bytes)) AS pico_necessario
  FROM chunk_compression_stats('transactions');
```

**Critério de aborto:** se o espaço livre for menor que o maior chunk
descomprimido, **pare**. Descomprimir vai encher o disco e transformar um
incidente de capacidade num incidente de indisponibilidade. Nesse caso, escale
para aumento de volume antes — é a única saída segura.

### 1.3 Confirmar que os CAggs materializaram o período

**Este é o passo que impede a perda irreversível.**

```sql
-- Até onde cada CAgg materializou. O watermark precisa estar DEPOIS do
-- range_end do chunk que se pretende apagar.
SELECT ca.view_name,
       _timescaledb_functions.to_timestamp(
         _timescaledb_functions.cagg_watermark(c.mat_hypertable_id)
       ) AS materializado_ate
  FROM timescaledb_information.continuous_aggregates ca
  JOIN _timescaledb_catalog.continuous_agg c ON c.user_view_name = ca.view_name
 ORDER BY 1;
```

Se algum CAgg estiver atrasado, **materialize antes de qualquer remoção**:

```sql
CALL refresh_continuous_aggregate('cagg_volume_hourly',
                                  '2025-09-01'::timestamptz,
                                  '2026-03-01'::timestamptz);
CALL refresh_continuous_aggregate('cagg_settlement_latency_daily',
                                  '2025-09-01'::timestamptz,
                                  '2026-03-01'::timestamptz);
```

### 1.4 Janela combinada e stakeholders avisados

Sem downtime não quer dizer sem comunicação — ver Seção 6.

---

## 2. Validação inicial — listar candidatos e estimar o ganho

```sql
-- Chunks de 6+ meses, com tamanho e se o CAgg já cobre cada um.
-- A coluna cagg_cobre é o semáforo: 'f' significa NÃO TOQUE.
SELECT c.chunk_name,
       c.range_start::date,
       c.range_end::date,
       c.is_compressed,
       pg_size_pretty(s.total_bytes) AS tamanho,
       (_timescaledb_functions.to_timestamp(
          _timescaledb_functions.cagg_watermark(ca.mat_hypertable_id)
        ) >= c.range_end) AS cagg_cobre
  FROM timescaledb_information.chunks c
  JOIN LATERAL (SELECT total_bytes FROM chunks_detailed_size('transactions') d
                 WHERE d.chunk_name = c.chunk_name) s ON true
  CROSS JOIN _timescaledb_catalog.continuous_agg ca
 WHERE c.hypertable_name = 'transactions'
   AND ca.user_view_name = 'cagg_volume_hourly'
   AND c.range_end < now() - INTERVAL '6 months'
 ORDER BY c.range_start;
```

```sql
-- Total a recuperar. Neste ambiente: 156 chunks, 1.111 MB.
SELECT count(*) AS chunks,
       pg_size_pretty(sum(s.total_bytes)) AS espaco_a_recuperar
  FROM timescaledb_information.chunks c
  JOIN LATERAL (SELECT total_bytes FROM chunks_detailed_size('transactions') d
                 WHERE d.chunk_name = c.chunk_name) s ON true
 WHERE c.hypertable_name = 'transactions'
   AND c.range_end < now() - INTERVAL '6 months';
```

**Critério de aborto:** se algum candidato tiver `cagg_cobre = false`, remova-o
da lista e materialize o CAgg primeiro (§ 1.3).

---

## 3. Execução — chunk por chunk, nunca em lote

> **Nunca em lote.** Um `DROP` em massa que erra no meio deixa o estado
> ambíguo: parte apagada, parte não, e sem saber onde parou. Chunk por chunk,
> cada um com sua validação, é auditável e interrompível a qualquer momento.

Para **cada** chunk da lista, nesta ordem:

### 3.1 Valida — o CAgg cobre este chunk?

```sql
SELECT (_timescaledb_functions.to_timestamp(
          _timescaledb_functions.cagg_watermark(ca.mat_hypertable_id)
        ) >= c.range_end) AS pode_remover
  FROM timescaledb_information.chunks c
  CROSS JOIN _timescaledb_catalog.continuous_agg ca
 WHERE c.chunk_name = '_hyper_1_1349_chunk'
   AND ca.user_view_name = 'cagg_volume_hourly';
```

**`false` → pule este chunk.** Não force.

### 3.2 Sanitiza (só se houver PII a remover)

Em `transactions` **não há PII por design** — ela vive só em `accounts`, que
não é hypertable e não entra neste procedimento. Se a sanitização for exigida
por política ainda assim, o chunk precisa ser descomprimido antes:

```sql
SELECT decompress_chunk('_timescaledb_internal._hyper_1_1349_chunk');
-- ... UPDATE de anonimização ...
SELECT compress_chunk('_timescaledb_internal._hyper_1_1349_chunk');
```

> **Atenção ao custo:** descomprimir infla o chunk ~5,5× de forma transitória.
> A 92% de uso, faça **um por vez** e confira o espaço entre cada um. Se o
> objetivo for só liberar espaço (o caso deste cenário), **pule esta etapa** —
> vá direto ao 3.3, que não precisa descomprimir.

### 3.3 Remove

```sql
SELECT drop_chunks('transactions',
                   older_than => '2025-09-02'::timestamptz,
                   newer_than => '2025-09-01'::timestamptz);
```

`newer_than` + `older_than` delimitam **um** chunk. Sem `newer_than`, o comando
apaga tudo que for mais antigo — que não é o que se quer aqui.

### 3.4 Confere

```sql
-- O agregado sobreviveu? A contagem do período tem de ser a MESMA de antes.
SELECT sum(tx_count) AS total_agregado
  FROM cagg_volume_hourly
 WHERE bucket >= '2025-09-01' AND bucket < '2025-09-02';
```

**Se este número mudou, PARE imediatamente** e vá para a Seção 5.

---

## 4. Checkpoints

**Após cada chunk:**

```sql
-- 1. Total do CAgg no período tratado — não pode ter mudado
SELECT count(*) AS buckets, sum(tx_count) AS transacoes
  FROM cagg_volume_hourly WHERE bucket < now() - INTERVAL '6 months';

-- 2. Espaço liberado de fato
SELECT pg_size_pretty(hypertable_size('transactions')) AS tamanho_atual;
```

**A cada 5 chunks — pausa obrigatória e reavaliação:**

| Verificação | Critério de seguir |
|---|---|
| Uso do disco caiu? | Sim, de forma proporcional ao removido |
| Total dos CAggs intacto? | Idêntico ao registrado antes de começar |
| Escrita seguindo normal? | `sync_last_success_timestamp` fresco no dashboard |
| Alguma query de aplicação quebrou? | `api_requests_total{outcome="error"}` estável |

**Critério de aborto geral:** qualquer divergência no total do CAgg, ou uso de
disco que **não** cai após remoções — para tudo e investiga.

---

## 5. Rollback

**Seja honesto sobre o que é reversível:**

| Situação | Reversível? | Como |
|---|---|---|
| Chunk removido, CAgg íntegro | Não precisa | Era o objetivo |
| Chunk removido, CAgg furado | **Só via backup** | § 5.1 |
| Chunk descomprimido, disco encheu | Sim | `compress_chunk()` imediato |
| Procedimento interrompido no meio | Sim | Estado é consistente: chunk é unidade atômica |

### 5.1 Se o agregado furou

```bash
# 1. Restaurar em instância PARALELA — nunca sobre o banco principal.
#    O drill já faz exatamente isso na 5499.
bash desafio-3/backup/restore-drill.sh
```

```sql
-- 2. Reprocessar o CAgg a partir do dado restaurado, só na janela afetada
CALL refresh_continuous_aggregate('cagg_volume_hourly',
                                  '<inicio_afetado>', '<fim_afetado>');
```

**Critério de aborto definitivo:** se o dado bruto não existir mais **nem no
backup**, o agregado daquele período é irrecuperável. Escale para a liderança —
é decisão de negócio se o período pode ficar sem detalhe, não decisão técnica.

---

## 6. Comunicação

| Momento | Público | Mensagem |
|---|---|---|
| **T-30min** | `#dados-operacao` + on-call | "Iniciando sanitização de chunks antigos. **Sem downtime previsto**; leitura e escrita seguem normais. Storage em 92%." |
| **A cada 30 min** | `#dados-operacao` | "Progresso: N/156 chunks. Storage em X%. Sem intercorrência." |
| **Se abortar** | on-call + liderança | "Procedimento interrompido em N/156. Motivo: `<critério>`. Storage em X%. Dado íntegro; sem impacto em consulta." |
| **T+fim** | `#dados-operacao` + liderança | "Concluído. 156 chunks removidos, 1.111 MB liberados, storage de 92% para X%. Agregados conferidos, 0 divergência." |
| **D+1** | Liderança | Post-mortem: por que chegou a 92%, e qual política evita a repetição |

**O ponto mais importante da comunicação inicial:** dizer explicitamente que
**não há downtime e as consultas seguem funcionando**. "Manutenção no banco de
transações" sem essa qualificação faz o time comercial presumir que o
faturamento parou.

---

## 7. Prevenção — para não repetir

O runbook resolve o sintoma. As ações abaixo atacam a causa:

| Ação | Tipo |
|---|---|
| Alerta de storage em **85%**, não 92% | Detectivo — dá margem para o procedimento ainda ser executável |
| Política de retenção **ligada** com janela acordada | **Preventivo** — hoje está desabilitada de propósito (90d × dataset de 12 meses) |
| Revisão trimestral de capacidade × crescimento | **Preventivo** |
| Checar `cagg_cobre` no próprio job de retenção | **Preventivo** — impede a remoção perigosa por automação |
