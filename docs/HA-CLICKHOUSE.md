# Alta disponibilidade do ClickHouse

[← Voltar ao README](../README.md)

Responde ao **risco nº 1** do [sumário executivo](SUMARIO-EXECUTIVO.md): o
ClickHouse roda em nó único. Este documento traz a decisão, o custo medido dessa
escolha, o caminho de migração para produção — e o modo replicado que **existe,
roda e foi testado** neste repositório.

## Por que o desafio roda em nó único

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

## O que muda em produção

| Componente | Local | Produção |
|---|---|---|
| Engine | `ReplacingMergeTree` | `ReplicatedReplacingMergeTree` |
| Coordenação | — | ClickHouse Keeper, 3 nós em AZs distintas |
| Instâncias | 1 | 2 réplicas (cenário atual) → 2 shards × 2 réplicas (10×) |
| DDL | Por nó | `ON CLUSTER` |
| Leitura | Direta | Distribuída, com `load_balancing` |
| Custo | — | $280/mês → **$1.120/mês** no cenário 10× ([CUSTO-AWS](CUSTO-AWS.md)) |

## Sequência de migração

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
senão o Data Champion autentica numa réplica e falha na outra. Verificado neste
projeto: o RBAC sobreviveu à recriação do container porque está no volume.

## O modo HA existe, roda e foi medido

O plano acima **não ficou só no papel**. `docker-compose.ha.yml` sobe a
topologia completa — 3 Keepers em quórum + 2 réplicas — e
`scripts/tests/ha-smoke.sh` prova que ela replica de verdade:

```bash
docker compose -f docker-compose.yml -f docker-compose.ha.yml up -d
bash scripts/tests/ha-smoke.sh
```

**Resultado medido: 11 verificações, 0 falhas.**

| Verificação | Resultado |
|---|---|
| Réplicas 1 e 2 conectadas ao Keeper | ✅ |
| `trio_cluster` com 2 réplicas, macros `{replica}` distintas e `{shard}` igual | ✅ |
| DDL `ON CLUSTER` propagou sem ser executado na réplica 2 | ✅ |
| 3 linhas escritas em r1 apareceram em r2 | ✅ |
| Replicação **bidirecional** (escrita em r2 chegou em r1) | ✅ |
| **Leitura continua com a réplica 1 derrubada** | ✅ |
| **Escrita continua com a réplica 1 derrubada** (quórum mantido) | ✅ |
| **Réplica 1 recuperou sozinha o que perdeu** ao voltar | ✅ |

Fica **fora** do `up` padrão de propósito: o critério de aceite nº 1 do PDF é o
ambiente subir com um comando, e cada peça a mais é uma chance a mais de falhar
na frente da banca. Mas a resposta para "e a alta disponibilidade?" agora é um
comando, não uma promessa.

## O que este teste prova e o que não prova

Ser honesto aqui vale mais que o teste em si:

| Prova | Não prova |
|---|---|
| Topologia, quórum, DDL `ON CLUSTER`, macros | Tolerância a falha de **infraestrutura real** |
| Replicação bidirecional e recuperação automática | Sobrevivência à queda de uma **AZ inteira** |
| Que a leitura e a escrita sobrevivem à perda de 1 de 2 réplicas | Latência de replicação sob carga de produção |

Os 3 Keepers e as 2 réplicas rodam na **mesma máquina**: derrubar um container
prova que o mecanismo de replicação funciona, não que o data center pode cair.
Em produção são 3 Keepers em 3 AZs e réplicas em AZs separadas — o custo está
em [CUSTO-AWS](CUSTO-AWS.md).

## Três armadilhas que só apareceram montando isto

Nenhuma está na documentação oficial de forma óbvia, e as três custaram loop de
restart até a causa aparecer:

| Sintoma | Causa | Correção |
|---|---|---|
| Loop de restart, sem erro no stdout | `load_balancing` no **nível raiz** do config — é setting de **usuário** | Movido para `<profiles><default>` |
| Loop de restart após declarar RBAC replicado | `<user_directories>` **substitui** a configuração de acesso e desmonta o usuário criado pelo entrypoint do Docker | Bloco mantido **comentado**, com o porquê; em produção não há conflito |
| `from_env` na senha da réplica | A versão recusa a substituição quando o elemento tem valor inline | Senha direta; em produção vem do Secrets Manager |

**A lição operacional das três é a mesma:** o ClickHouse falha na inicialização
com `exit 137` e o stdout do container só mostra *"Logging errors to
/var/log/..."*. A causa real está **dentro do volume**, em
`clickhouse-server.err.log` — quem não souber ir buscar lá fica cego.

```bash
docker run --rm -v trio-data-challenge_clickhouse_logs:/l alpine \
  tail -30 /l/clickhouse-server.err.log
```

---
