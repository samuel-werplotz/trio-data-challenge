# 09 — LGPD E SANITIZAÇÃO  [local]

## ORIGEM
`../vault-estudo/06-Especificacao/S05-LGPD-Sanitizacao.md` (S09) § inteiro — § O problema, em três camadas · § A arquitetura que evita o problema · § O procedimento de exclusão (passos 1–3) · § E se a PII estivesse no chunk comprimido? (A, B, C) · § Comparação final · § Tabela de auditoria · § Prazo legal · § Checklist de verificação

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
Verificado ao fechar a etapa 08:
- **`accounts` continua tabela comum, sem compressão e sem ser hypertable** — é a pré-condição central desta etapa. A compressão da 08 foi habilitada **só em `transactions`**; `reconciliation_events` também segue descomprimida. Ou seja: o `UPDATE` de anonimização de S09 funciona direto, sem descomprimir nada. A premissa "PII só em `accounts`" segue intacta.
- `init/timescaledb/04_caggs_policies.sql` aplicado. Existem 2 CAggs, **ambos livres de PII por design** (agregam por `type`/`status`/`source_institution`, nunca por conta): `cagg_volume_hourly` (79.396 buckets) e `cagg_settlement_latency_daily` (20.280 buckets). Isso importa para a camada 2 do problema de S09 — aqui os agregados **não** contêm PII, e o documento pode afirmar isso com o schema na mão.
- Compressão ativa em `transactions`: 330 de 338 chunks comprimidos, `segmentby='source_institution, type'`. **Taxa de 5,0× no total, 23,5× só na tabela** — os 4 índices da etapa 07 (1.484 MB) pesam mais que os dados (1.188 MB) e puxam o total para baixo.
- 3 políticas de retenção: `transactions` 90d **desligada** (`scheduled=false`, conflito com o dataset de 12 meses), `cagg_volume_hourly` e `cagg_settlement_latency_daily` 2 anos **ligadas**. `desafio-1/scripts/retention-demo.sh` demonstra a do raw sem destruir dado (insere linhas em 2020, calibra `drop_after`, roda `CALL run_job`, restaura).
- **Limitação nova a considerar:** `timescaledb_toolkit` **não existe** na imagem fixada, então não há `percentile_agg`/TDigest disponível. O CAgg 2 materializa só colunas somáveis e o P95/P99 sai da view `v_settlement_latency_percentiles` (`percentile_cont` sobre o raw). Se esta etapa precisar de função do toolkit, ela não está lá.
- Q1 otimizada criada (`q1_volume_por_tipo_status_optimized.sql`, lê do CAgg): 12.115ms → 23ms (**521×**). Q3 ganhou 3ª versão via CAgg (`q3_top_instituicoes_cagg.sql`): 1.285ms → 3,4ms (383×). `explains/q1_after.txt` e `q3_cagg_after.txt` gravados. `run-explains.sh` no ramo `after` roda as duas.
- `REPORT.md` completo: tabela sem lacunas, mais seções de compressão, retenção e limitação do toolkit.
- **Armadilha documentada:** `failed_count`/`total_count` de `cagg_settlement_latency_daily` são estruturalmente enganosos (o `WHERE settled_at IS NOT NULL` exclui todo `failed`). Comentado no DDL; taxa de falha vem do `cagg_volume_hourly`.
- `run_all.sh`: blocos 01–08, **53 pass / 0 fail / 4 skip**. Teste `06.4` foi reescrito nesta etapa (asseria "0 CAggs"); desvio em `99-validacao-final.md`.
- Containers de pé: `timescaledb` e `postgres-legado`, ambos healthy. `transactions` com 10.000.000 linhas confirmadas após compressão + demo de retenção.

## ESCOPO
Faz: `lgpd_erasure_log` (tabela de auditoria), o procedimento de anonimização em 3 passos, e `desafio-1/lgpd-sanitization.md` comparando as 3 estratégias e justificando a escolha da tabela lateral (opção C).
Não faz: não altera o schema de `accounts`, `transactions` ou dos CAggs; não apaga dado real do dataset — o procedimento é demonstrado, não aplicado em massa.

## PASSOS
1. Escrever o documento explicando o problema nas 3 camadas de S09: chunk comprimido resiste a alteração, agregados também podem conter PII, e o dado já foi replicado.
2. Documentar a arquitetura que **evita** o problema: toda a PII vive só em `accounts`, que não é hypertable nem é comprimida — por isso o `UPDATE` de anonimização funciona direto.
3. Criar `lgpd_erasure_log` conforme S09 § Tabela de auditoria.
4. Implementar o procedimento em 3 passos: anonimizar na origem → propagar ao ClickHouse → tratar backups. Cada passo com o comando exato.
5. Escrever a comparação das 3 estratégias (A: descomprimir/alterar/recomprimir; B: crypto-shredding; C: tabela lateral) com a tabela de S09 § Comparação final e a justificativa da escolha C.
6. Registrar o prazo legal de S09 § Prazo legal.
7. Rodar o checklist de S09 § Checklist de verificação e acrescentar o bloco `# --- 09 lgpd-sanitizacao ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [x] `desafio-1/lgpd-sanitization.md` existe e cobre as 3 camadas do problema
- [x] As 3 estratégias estão comparadas, com a escolha da C justificada — não só afirmada
- [x] `lgpd_erasure_log` criada com os campos de S09
- [x] Procedimento de anonimização escrito com comando exato para cada um dos 3 passos
- [x] Documento afirma e demonstra que PII vive só em `accounts` (queries reais no doc)
- [x] Prazo legal registrado
- [x] Checklist de verificação de S09 passa item a item (itens 1/2/5 executados no demo; 3/4 documentados como futuros — CH/CDC ainda não existem)

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 09.1 | local | `test -f desafio-1/lgpd-sanitization.md` | sai 0 |
| 09.2 | local | `grep -ci 'crypto\|tabela lateral\|descomprimir' desafio-1/lgpd-sanitization.md` | ≥ 3 (as 3 estratégias) |
| 09.3 | compose | `psql -c "SELECT to_regclass('lgpd_erasure_log')"` | não nulo |
| 09.4 | compose | anonimizar 1 conta de teste e conferir `lgpd_erasure_log` | 1 linha registrada |
| 09.5 | compose | `psql -c "SELECT count(*) FROM information_schema.columns WHERE table_name='transactions' AND column_name IN ('cpf','email','name')"` | `0` (sem PII fora de `accounts`) |

## ROLLBACK
```bash
docker compose exec -T timescaledb psql -U trio -d trio -c "
DROP TABLE IF EXISTS lgpd_erasure_log CASCADE;
DROP PROCEDURE IF EXISTS anonimizar_conta(BIGINT);"
git checkout -- desafio-1/lgpd-sanitization.md
```

## STATUS
Estado: CONCLUÍDA
Premissas assumidas:
- Teste do procedimento rodado sobre conta sintética descartável, não conta real — confirmado com o usuário (mesmo padrão do `retention-demo.sh`).
- Passo 2 (ClickHouse) documentado como procedimento futuro, não executado: etapas 11 e 13 ainda não existem neste ambiente.
- `pgcrypto` habilitado via `CREATE EXTENSION` no `05_lgpd_erasure.sql` — disponível na imagem, só não instalado por padrão.

Desvios do plano: nenhum. Nenhuma atualização em `99-validacao-final.md` para esta etapa.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (09.1–09.7)
- [x] run_all.sh sem FAIL — 60 pass / 0 fail / 4 skip
- [x] ESTADO HERDADO da próxima preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → nenhum, 99-validacao-final.md não alterado
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
