# LOG DE EXECUÇÃO

Scratchpad descartável, não histórico permanente. Mínimo, sem prosa. Campo que não se aplica é omitido. Nunca repetir o que já está no commit ou no `.md` da etapa concluída.

Formato do bloco, um por etapa:

```
## NN · AAAA-MM-DD
Quebrou: <o que falhou, ou omitir>
Decidido: <o que foi decidido, ou omitir>
```

---

## 01 · 2026-08-03

## 02 · 2026-08-03
Decidido: paths de build local sem S-doc (ref-sync, api) seguem convenção do cdc-consumer (S05: `desafio-2/pipeline/<serviço>/`). Validação de `up --profile core` restrita aos 4 serviços com imagem pronta — seed/api (build) ficam para 05/14.

## 03 · 2026-08-03
Quebrou: `winget install GnuWin32.Make` falhou por erro de rede (Sourceforge). Sem `make` no PATH deste Windows.
Decidido: validar `make help`/`make -n up`/`make seed`/`make check` via container Docker auxiliar (`docker:27-cli` + socket montado + `COMPOSE_PROJECT_NAME` explícito), já que Docker está de pé. `run_all.sh` faz SKIP nos 3 testes que dependem de `make` neste ambiente específico.

## 04 · 2026-08-03
Quebrou: primeira versão de `02_seed_marker.sql` usou colunas inventadas em vez das literais de S02 — pego ao ler a ORIGEM da etapa 05, corrigido antes do commit.
Decidido: volume do timescaledb recriado 2x (schema inicial + correção do seed_control) — sem perda de dado real, nenhum seed havia rodado.

## 05 · 2026-08-04
Quebrou: `COPY BINARY` com `float`/sem `set_types` corrompia o stream binário (NUMERIC e CHAR(3)); timestamps do mês corrente geravam dado no futuro. Todos corrigidos antes do seed real rodar.
Decidido: seed real de 10M rodou em 1m57s (vs ~20min estimado em S02) — 6 workers, COPY BINARY em lotes de 50k. 12 meses do dataset terminam no mês corrente para a janela de pending/48h cair dentro do range.

## 06 · 2026-08-04
Quebrou: Q4 (self-join) estourava `/dev/shm` (64MB default) — nosso volume em 7 dias é ~5x a referência de S06.
Decidido: `shm_size: 1gb` no serviço timescaledb (docker-compose.yml). Medianas registradas: Q1 12.115ms, Q2 8.103ms, Q3 1.285ms, Q4 2.814ms (self-join mais rápido que o esperado — planejador usou Parallel Hash Join).

## 07 · 2026-08-04
Quebrou: gerador de `reconciliation_events` (etapa 05) fazia 86% das linhas divergirem (divergência percentual do valor) e gravava `reconciled_at = now()` em todas — as duas coisas invalidavam a premissa do índice parcial de Q2 e o filtro de 30 dias. Corrigido e só essa tabela recarregada; Q2 remedida do zero (before + after).
Decidido: Q2 entra no REPORT como "índice que não melhorou" — ambos os índices são usados, mas o gargalo é o Seq Scan no lado de `transactions` do join. Testes 04.6/06.3 reescritos (asseriam "sem índice", que esta etapa invalida por design).

## 08 · 2026-08-04
Quebrou: `timescaledb_toolkit` não existe na imagem fixada `latest-pg16` — `percentile_agg`, que S03 usa no CAgg 2, é inalcançável sem trocar a imagem (proibido pela Seção 2). Adotado o plano B que o próprio S03 prevê, com confirmação do usuário.
Quebrou: `failed_count` do CAgg 2 é estruturalmente 0 — o `WHERE settled_at IS NOT NULL` de S03 exclui toda transação `failed`. Schema mantido (é contrato), mas a coluna ganhou aviso no DDL e a Q3 via CAgg não calcula taxa de falha.
Decidido: compressão deu **5,0× no total** mas **23,5× só na tabela** — os 4 índices da etapa 07 pesam 1.484 MB contra 1.188 MB de dado, e é isso que puxa a taxa para baixo dos 10–20× que S03 esperava. O número virou seção do REPORT em vez de nota de rodapé: as duas otimizações do desafio se pagam uma contra a outra.
Decidido: Q1 12.115ms → 23ms (**521×**, buffers 95.670 → 500); Q3 via CAgg 1.285ms → 3,4ms (383×). Equivalência do CAgg com o raw verificada linha a linha — 0 divergências, mas só com o corte alinhado a `date_trunc('hour')`; no meio do bucket o mês da borda diverge em ~193 linhas.

## 09 · 2026-08-04
Decidido: `pgcrypto` não vinha instalado (só `digest()` do procedimento de S09 precisa dele) — `CREATE EXTENSION IF NOT EXISTS pgcrypto` resolvido no próprio `05_lgpd_erasure.sql`, sem o tipo de conflito do toolkit da etapa 08 (extensão disponível na imagem, só não habilitada).
Decidido: teste do procedimento `anonimizar_conta` rodado sobre conta **sintética** (`desafio-1/scripts/lgpd-erasure-demo.sh`), não sobre uma das 500k contas reais — mesmo padrão do `retention-demo.sh` da etapa 08. Confirmado com o usuário antes de escrever, dado que o UPDATE de anonimização é irreversível sobre dado real.
Decidido: Passo 2 (propagação ao ClickHouse) documentado como procedimento futuro, não executável — ClickHouse (etapa 11) e CDC (etapa 13) ainda não existem neste ambiente. Checklist de S09 mantém os 5 itens, mas o doc marca quais são verificáveis hoje.

## 10 · 2026-08-04
Quebrou: ao medir o bloat pela primeira vez rodei `ANALYZE` manual por engano antes de capturar o "antes" — contaminava o cenário de estatística desatualizada que S07 pede. Resolvido truncando e recarregando o legado do zero (`RESTART IDENTITY CASCADE`), com `autovacuum_enabled=false` em `legacy_accounts`/`institution_configs` para o "antes" não ser corrigido sozinho pelo autovacuum antes da medição.
Quebrou: seed original de `legacy_accounts`/`legacy_configs` assumia ids sequenciais a partir de 1 (`1 + g % 15`); `SERIAL` não é transacional, então uma segunda tentativa após rollback deixava buracos e a FK falhava. Corrigido para montar `array_agg(id ORDER BY id)` uma vez e indexar, em vez de assumir contiguidade.
Quebrou: teste `06.2` do `run_all.sh` (esperava 4 arquivos `Buffers:` em `*_before.txt`) quebrou com os `legacy_qN_before.txt` novos no mesmo diretório. Glob restrito a `q[1-4]_before.txt`.
Decidido: bloat medido em 83,3% de linhas mortas, `legacy_accounts` ocupando 70 MB para 80.000 linhas úteis (~6×) — dentro do previsto por S07. Legacy Q1 não mudou de tempo após ANALYZE (o planner já escolhia Hash Join mesmo com estimativa errada); o ganho real foi na precisão da estimativa (509.298→80.000 linhas). Reportado como está, sem forçar a narrativa do Nested Loop que S07 previu mas não se manifestou nesta escala.

## audit.sh · 2026-08-04
Quebrou: `audit.sh` só buscava etapas em `scripts/roadmap/*.md` — depois que uma etapa fecha e move para `concluidas/`, o script deixa de achá-la e reporta FAIL falso (arquivo ausente, esteira com número errado de etapas BLOQUEADA, decisões/PDF não rastreados). Regressão silenciosa a cada fechamento de etapa desde a 02.
Decidido: `step_file NN` resolve o caminho da etapa em `$ROADMAP` ou `$ROADMAP/concluidas`; `has_impeditivo_ficha` checa só dentro da seção `## IMPEDITIVOS` (não em prosa livre de STATUS) para não pegar falso-positivo. A6.2 (código de aplicação "antes da hora") virou condicional a `-d trio-data-challenge` — só faz sentido antes da etapa 01. `audit.sh` volta a 0 FAIL de forma estável, não é mais preciso ignorar FAILs "conhecidos" a cada fechamento.
