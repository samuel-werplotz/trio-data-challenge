# Alta disponibilidade do ClickHouse e roteiro de demonstração

Duas coisas que faltavam para a entrega estar pronta para a banca: o **plano de
HA escrito** (o risco nº 1 do [sumário executivo](SUMARIO-EXECUTIVO.md)) e o
**roteiro da apresentação**, com as respostas de 20 segundos para os três pontos
que geram dúvida ao vivo.

---

## Parte 1 — HA do ClickHouse

### Por que o desafio roda em nó único

Decisão consciente, não omissão. Réplica exige **ClickHouse Keeper** (3 nós, por
quórum) mais uma segunda instância: 4 containers a mais para demonstrar uma
propriedade que não muda nenhuma resposta do desafio. O critério de aceite nº 1
é `docker compose up -d` subir tudo — quanto mais peça, mais frágil esse
critério fica.

**O que o nó único custa hoje**, medido e não estimado:

| Se o ClickHouse cair | Impacto |
|---|---|
| Dado perdido | **Nenhum.** O ClickHouse é destino, não fonte da verdade — o TimescaleDB tem tudo |
| Tempo para reconstruir | **~56 s** (`scripts/backfill-clickhouse.sh` refaz os 10M) |
| Durante a queda | Dashboards, API e Data Champions param |
| Recuperação do incremental | Automática — o `sync-worker` reassume pelo watermark |

É por isso que o backup do ClickHouse é **otimização de RTO, não seguro contra
perda** (`desafio-3/backup/README.md`). O risco real não é perder dado; é ficar
sem plataforma analítica pelo tempo do backfill.

### O que muda em produção

| Componente | Local | Produção |
|---|---|---|
| Engine | `ReplacingMergeTree` | `ReplicatedReplacingMergeTree` |
| Coordenação | — | ClickHouse Keeper, 3 nós em AZs distintas |
| Instâncias | 1 | 2 réplicas (cenário atual) → 2 shards × 2 réplicas (10×) |
| DDL | Por nó | `ON CLUSTER` |
| Leitura | Direta | Distribuída, com `load_balancing` |
| Custo | — | $280/mês → **$1.120/mês** no cenário 10× ([CUSTO-AWS](CUSTO-AWS.md)) |

### Sequência de migração

A ordem importa: `CREATE ... Replicated*` **falha** se o Keeper não existir.

```
1. Subir o Keeper (3 nós, quórum)                    ← sem impacto no serviço
2. Subir a 2ª instância de ClickHouse
3. Migrar a engine tabela por tabela                 ← procedimento abaixo
4. Apontar a leitura para o endpoint distribuído
5. Retirar o nó antigo depois de 72 h                ← janela de segurança
```

O passo 3 é exatamente o **procedimento de tabela sombra + `EXCHANGE TABLES`**
documentado em [`desafio-2/PROCEDIMENTOS-PRODUCAO.md`](../desafio-2/PROCEDIMENTOS-PRODUCAO.md)
§ 2 — tabela nova com a engine de destino, dupla escrita por MV, backfill por
partição, validação **por partição** e troca atômica.

**Ordem entre as tabelas:** as MVs de agregação primeiro (menores, e um erro
nelas se corrige com `TRUNCATE` + backfill), a `transactions_raw` por último.

**O que também é estado, e quase se esquece:** o **RBAC** (`analytics_ro`,
quotas, perfis) vive em `/var/lib/clickhouse/access/`, não nas tabelas. Num
cluster ele precisa de `ON CLUSTER` ou de `replicated` no `user_directories` —
senão o Data Champion autentica numa réplica e falha na outra. Verificado na
etapa 19: o RBAC sobreviveu à recriação do container porque está no volume.

### Por que não Keeper local, mesmo sendo possível

Subir 3 Keepers em Docker demonstraria a configuração, **não a propriedade**: um
failover real exige derrubar um nó e provar que a leitura continua — e com todos
os nós na mesma máquina, o teste prova apenas que containers reiniciam. Preferi
o plano escrito e o custo calculado a uma encenação que não sobreviveria a
"e se a AZ inteira cair?".

---

## Parte 2 — Roteiro de demonstração

**45 minutos** (PDF § 2.1 e § 7), com ordem de corte para 30. Os **4 blocos** do
§ 7 são obrigatórios — o de incidente é o que mais se esquece de ensaiar.

| Bloco | Tempo | O quê | Corta em 30 min? |
|---|---|---|---|
| 0 · Abertura | 2 min | Sumário executivo: 5 números, 3 riscos | Não |
| 1 · Ambiente | 8 min | `docker compose ps`, contagens, `run_all.sh` | Reduz para 4 min |
| 2 · Decisões | 12 min | CDC descartado, ORDER BY, Dictionary, micro-batch | Não |
| 3 · Demonstrações | 10 min | Pipeline, Q4, LGPD, restore | Só pipeline + Q4 |
| 4 · Incidente | 8 min | SEV-1: árvore de hipóteses | Não |
| 5 · Perguntas | 5 min | — | — |

### As 3 respostas de 20 segundos

Cada uma responde algo que **parece erro** e não é. Ensaiar até sair sem
hesitação: a hesitação é o que transforma dúvida em desconfiança.

---

**1. "O P95 de liquidação é 15 horas?!"**

> «É artefato do gerador, e está declarado no REPORT. O seed distribui
> `settled_at` ao longo de uma janela larga para criar variância nos
> dashboards — não modela o SLA real do Pix, que é de segundos. O que a métrica
> **prova** é que o cálculo de percentil por instituição funciona sobre 10
> milhões de linhas em 3,4 ms. Se o dado fosse real, o número seria outro; o
> caminho seria o mesmo.»

Se insistirem: o número vem de `v_settlement_latency_percentiles`, e
`failed_count` é estruturalmente 0 porque o CAgg filtra `settled_at IS NOT NULL`
— também declarado.

---

**2. "A Q4 devolveu 0 linhas. A query está errada?"**

> «Zero é o resultado correto: o gerador não produz duplicata em janela de 5
> minutos. Para não depender da minha palavra, tem um cenário plantado —»

```bash
bash desafio-1/scripts/q4-cenario-demo.sh
```

> «— ele insere 3 cobranças idênticas de R$ 149,90 com 90 s entre elas, a Q4
> passa de 0 para **2 detecções** (pares consecutivos: 1→2 e 2→3), e o script
> limpa tudo e confere as contagens. Mesmo padrão do `/fraud/duplicates` na
> API: a lógica foi provada sobre dado sintético para separar *não achou porque
> não existe* de *não achou porque está errada*.»

---

**3. "Isso não é saída de LLM?"**

Não responder com adjetivo. Abrir o terminal:

```bash
git log --oneline
```

> «São 30+ commits com o processo real. Este aqui —» (`328e8a9`) «— é uma etapa
> inteira **descartada**: montei o CDC com Debezium, não funcionou sobre
> hypertable, provei a causa (`publish_via_partition_root` não se aplica porque
> hypertable não é tabela particionada nativa) e troquei a abordagem. O
> experimento ficou no repositório como artefato da decisão.»

E o argumento mais forte, se houver tempo:

> «Dois defeitos foram encontrados **medindo**, não revisando. O Dictionary
> resolvia 33,55% do volume porque os códigos de dois seeds nunca casaram — a
> API servia "desconhecida" para 66% das instituições. E o pipeline perdia dados
> em silêncio com lote acima de 50.000 linhas, porque o watermark não tinha
> desempate. Os dois estão corrigidos, com teste de regressão, e o registro do
> erro está no `LOG-EXECUCAO.md`. LLM não encontra isso — quem roda encontra.»

### Comandos da demonstração, na ordem

```bash
# Bloco 1 — o ambiente de pé
docker compose ps
docker exec trio-timescaledb psql -U trio -d trio_transactions -tAc "SELECT count(*) FROM transactions"
docker exec trio-clickhouse clickhouse-client -u trio --password trio2024 -q "SELECT count() FROM trio_analytics.transactions_raw"
bash scripts/tests/run_all.sh | tail -3

# Bloco 3 — as demonstrações
bash desafio-2/demo-sync-worker.sh        # pipeline: INSERT -> pending -> UPDATE -> settled
bash desafio-1/scripts/q4-cenario-demo.sh # detecção de duplicata (resposta 2)
bash desafio-1/scripts/lgpd-erasure-demo.sh
bash desafio-3/backup/restore-drill.sh    # RTO 22 s medido

# Se perguntarem sobre carga
cat desafio-2/saturacao-resultado.md
```

### Checklist de 10 minutos antes

- [ ] `docker compose ps` — 11 containers, os 4 com healthcheck em `healthy`
- [ ] Contagens em 10.000.000 nas 3 pontas (raw **e** as 2 MVs por `countMerge`)
- [ ] `run_all.sh` sem FAIL
- [ ] Grafana aberto em aba separada (`localhost:3000`, admin/admin)
- [ ] `git log` numa aba de terminal, pronto para a resposta 3
- [ ] Cenário de Q4 **testado uma vez** antes (ele limpa sozinho)
