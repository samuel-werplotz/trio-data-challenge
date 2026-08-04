# 09 — LGPD E SANITIZAÇÃO  [local]

## ORIGEM
`../vault-estudo/06-Especificacao/S05-LGPD-Sanitizacao.md` (S09) § inteiro — § O problema, em três camadas · § A arquitetura que evita o problema · § O procedimento de exclusão (passos 1–3) · § E se a PII estivesse no chunk comprimido? (A, B, C) · § Comparação final · § Tabela de auditoria · § Prazo legal · § Checklist de verificação

## IMPEDITIVOS
(vazio = liberado)

## ESTADO HERDADO
<preenchido pela etapa 08 ao fechar>

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
- [ ] `desafio-1/lgpd-sanitization.md` existe e cobre as 3 camadas do problema
- [ ] As 3 estratégias estão comparadas, com a escolha da C justificada — não só afirmada
- [ ] `lgpd_erasure_log` criada com os campos de S09
- [ ] Procedimento de anonimização escrito com comando exato para cada um dos 3 passos
- [ ] Documento afirma e demonstra que PII vive só em `accounts`
- [ ] Prazo legal registrado
- [ ] Checklist de verificação de S09 passa item a item

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
Estado: PENDENTE
Premissas assumidas: —
Desvios do plano: —

## FECHAMENTO
- [ ] Critérios atendidos
- [ ] Testes no run_all.sh
- [ ] run_all.sh sem FAIL
- [ ] ESTADO HERDADO da próxima preenchido
- [ ] Bloco no LOG-EXECUCAO.md
- [ ] Desvio? → atualizar 99-validacao-final.md
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
