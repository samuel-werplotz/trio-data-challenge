# 19 — SEGURANÇA E GOVERNANÇA  [compose]

> **Etapa criada na revisão de entrega.** O cliente é **Instituição de Pagamento
> autorizada pelo BC**. Hoje o repositório tem: senha em claro no compose e
> dentro do DDL do Dictionary (`trio2024`), **um único usuário** no ClickHouse
> sem nenhum perfil, criptografia em repouso mencionada só via SSE-KMS do
> backup, **log de apagamento LGPD mas nenhum log de leitura de PII**, e zero
> menção a PCI-DSS ou Resolução BCB 4.658. Num desafio de fintech regulada,
> isso não é detalhe — é o eixo que a banca sabe cobrar.

## ORIGEM
Revisão de entrega § 4.4; `docker-compose.yml` (credenciais em claro); `init/clickhouse/01_schema.sql` § DDL do `dict_institutions` (senha embutida no `SOURCE(POSTGRESQL(...))`); `desafio-1/lgpd-sanitization.md` § `lgpd_erasure_log`; `desafio-2/ADR.md` § rotação de credenciais (problema reconhecido, sem proposta); `desafio-3/backup/README.md` § SSE-KMS

## IMPEDITIVOS
- [ ] ClickHouse e os 2 PostgreSQL de pé — a matriz de perfis precisa ser validada contra o servidor real (um `GRANT` que não aplica é matriz de ficção)

## ESTADO HERDADO
Verificado ao fechar a etapa 16 (atualizar ao fechar a 18, se a 18 rodar antes):
- **Senha `trio2024` aparece em pelo menos 3 lugares**: `docker-compose.yml`, o `SOURCE(POSTGRESQL(...))` do `dict_institutions` em `init/clickhouse/01_schema.sql`, e os comandos de verificação do `README.md`. O ADR **reconhece** a rotação como problema em aberto e não propõe caminho. **Trocar a senha não é o entregável** — o entregável é o modelo de gestão de segredo (Secrets Manager / SSM) escrito, mais a remoção do segredo do lugar mais indefensável: o DDL versionado.
- **`.env` está no `.gitignore` e `.env.example` versionado** — a base para mover credencial existe e funciona. Chave privada do MinIO já saiu do versionamento no commit `17a90dc`, então há precedente do mesmo movimento nesta esteira.
- **ClickHouse tem um único usuário (`trio`) com tudo liberado.** Não existe `users.d/`, não existe `ROW POLICY`, não existe `QUOTA`. As etapas anteriores nunca precisaram — a 18 (Data Champions) passa a precisar, e é ela quem consome esta matriz.
- **Onde a PII realmente está**: só em `accounts` no TimescaleDB, por design de S01. `transactions` e os 2 CAggs são livres de PII; o ClickHouse **não guarda nenhuma coluna de PII** — verificado na etapa 16 por varredura de `system.columns`. Isso **encurta muito** a matriz de perfis: proteger `accounts` protege quase tudo.
- **`lgpd_erasure_log` existe e registra apagamento**, com demo funcional (`lgpd-erasure-demo.sh`). **Não há registro de leitura** — quem consultou `accounts`, quando, e trazendo quantas linhas. Numa auditoria regulatória, é a pergunta que vem primeiro.
- **Backup declara SSE-KMS no destino S3** (`desafio-3/backup/README.md`). O dado **vivo** — volume do Postgres, volume do ClickHouse, tráfego entre containers — não tem nada escrito: nem EBS encryption, nem TLS entre serviços.
- **Prometheus, Grafana e a API sobem sem autenticação** neste ambiente local (Grafana em admin/admin). Aceitável em Docker local, **inaceitável de deixar sem declarar** — a diferença entre "é local" e "esqueci" é a linha escrita.
- **Precedente de método a reaproveitar**: a etapa 16 fechou C2b declarando uma limitação em vez de resolvê-la, e isso contou a favor. Aqui vale o mesmo — o que não dá para implementar em Docker local vira requisito de produção **escrito e endereçado**, não silêncio.

## ESCOPO
Faz: escreve o modelo de segurança e governança que uma IP autorizada precisa apresentar — perfis por tabela, criptografia nas duas pontas, auditoria de acesso a PII, mapeamento regulatório — e implementa no ClickHouse a parte que o ambiente local suporta (usuários, quotas, políticas).
Não faz: não provisiona KMS, Secrets Manager ou IAM real (Seção 2 — AWS é documento); não troca a arquitetura de dados; não implementa TLS entre containers (declarado como requisito de produção, com o motivo).

## PASSOS
1. **`docs/SEGURANCA-E-GOVERNANCA.md` — matriz de perfis por tabela.** Linha = perfil, coluna = objeto (`transactions`, CAggs, `accounts`, `transactions_raw`, as 2 MVs, `dict_institutions`, `lgpd_erasure_log`), célula = nenhum / leitura / leitura+escrita. Perfis mínimos: `app` (a aplicação), `analytics_ro` (Data Champion — casar com a etapa 18), `pii_reader` (acesso a `accounts`, nominal e auditado), `ops` (operação e backup). Justificar cada acesso a `accounts`, que é o único objeto realmente sensível.
2. **Implementar no ClickHouse o que o ambiente suporta.** Criar `analytics_ro` via `init/clickhouse/users.d/`, com `GRANT SELECT` só nas MVs e na raw, `QUOTA` de queries/hora e os limites de `max_execution_time`/`max_memory_usage` da etapa 18 amarrados ao perfil — não como sugestão em documento, como configuração aplicada. **Não remover nem alterar o usuário `trio`**: quebraria o pipeline, a API e a suíte inteira.
3. **Segredo fora do DDL versionado.** A senha do Postgres dentro do `SOURCE(POSTGRESQL(...))` do `dict_institutions` é o caso mais indefensável — está num `.sql` commitado. Parametrizar (variável de ambiente na geração do DDL ou `named_collection` do ClickHouse) e escrever no documento o modelo de produção: Secrets Manager com rotação automática, quem roda a rotação, qual o impacto no Dictionary quando a senha gira. **Validar o Dictionary respondendo depois da mudança** — `dictGet` quebrado derruba a query de enriquecimento.
4. **Criptografia em trânsito e em repouso, nas duas pontas.** Em repouso: EBS/RDS encryption para o dado vivo, SSE-KMS no S3 (já existe), chave gerenciada por quem. Em trânsito: TLS entre aplicação e bancos, entre pipeline e ClickHouse, e no acesso do Data Champion. Declarar o que **não** está ligado no Docker local e por quê.
5. **Auditoria de acesso a PII.** Hoje só há log de apagamento. Implementar o registro de **leitura** de `accounts` — quem, quando, qual query, quantas linhas — e demonstrar funcionando com uma consulta de teste. Se a via mais direta for `pgaudit` e a extensão não existir na imagem fixada (a Seção 2 proíbe trocar imagem), usar a alternativa nativa (trigger de auditoria ou view instrumentada) e **registrar a escolha e o motivo** — mesmo padrão do `percentile_agg` na etapa 08.
6. **Mapeamento regulatório.** Tabela: requisito → o que a plataforma faz → onde está a evidência. Cobrir **Resolução BCB 4.658** (política de segurança cibernética, plano de resposta a incidente, requisitos de contratação de nuvem), **LGPD** (base legal, retenção, direito de eliminação — já implementado) e **PCI-DSS** no que se aplica (a plataforma não guarda PAN; **dizer isso explicitamente vale mais do que omitir**). Linkar cada linha a artefato que já existe: `incident-response.md`, `runbook.md`, `lgpd-sanitization.md`, `backup/README.md`.
7. **Retenção de log e trilha de auditoria.** Por quanto tempo o log de acesso e o de apagamento ficam, onde, e como se prova integridade (append-only, destino separado). Auditoria que o próprio operador pode reescrever não é auditoria.
8. Acrescentar o bloco `# --- 19 seguranca-e-governanca ---` em `scripts/tests/run_all.sh`.

## CRITÉRIOS DE ACEITE
- [ ] `docs/SEGURANCA-E-GOVERNANCA.md` com matriz perfil × objeto completa, incluindo `accounts` e as MVs
- [ ] Perfil `analytics_ro` **existe no ClickHouse**, com quota e limites aplicados — validado por conexão real, não só documentado
- [ ] `analytics_ro` **não** consegue ler o que a matriz nega — testado, não afirmado
- [ ] Senha fora do DDL versionado do `dict_institutions`, **com o Dictionary respondendo** depois da mudança
- [ ] Criptografia em trânsito e em repouso descritas nas duas pontas, com o que está desligado no local declarado
- [ ] Auditoria de **leitura** de `accounts` implementada e demonstrada com consulta de teste
- [ ] Mapeamento a BCB 4.658, LGPD e PCI-DSS, cada linha apontando artefato existente
- [ ] Usuário `trio` intacto — pipeline, API e `run_all.sh` seguem passando

## TESTES
| id | trilha | comando | esperado |
|---|---|---|---|
| 19.1 | local | `test -f docs/SEGURANCA-E-GOVERNANCA.md` | sai 0 |
| 19.2 | local | `grep -ci '4.658\|BCB' docs/SEGURANCA-E-GOVERNANCA.md` | ≥ 1 |
| 19.3 | local | `grep -ci 'pci' docs/SEGURANCA-E-GOVERNANCA.md` | ≥ 1 |
| 19.4 | local | `grep -ci 'em repouso' docs/SEGURANCA-E-GOVERNANCA.md` | ≥ 1 |
| 19.5 | local | `grep -ci 'em trânsito\|tls' docs/SEGURANCA-E-GOVERNANCA.md` | ≥ 1 |
| 19.6 | local | `! grep -q "trio2024" init/clickhouse/01_schema.sql` | sai 0 (segredo fora do DDL) |
| 19.7 | carga-real | `SELECT name FROM system.users` | contém `analytics_ro` |
| 19.8 | carga-real | `analytics_ro` faz `SELECT count() FROM trio_analytics.transactions_raw` | sai 0 |
| 19.9 | carga-real | `analytics_ro` tenta `DROP TABLE`/objeto negado pela matriz | falha com `ACCESS_DENIED` |
| 19.10 | carga-real | `SELECT count() FROM system.quotas WHERE name LIKE '%analytics%'` | ≥ 1 |
| 19.11 | carga-real | `dictGet('dict_institutions', ...)` após parametrizar o segredo | devolve valor, não erro |
| 19.12 | carga-real | consulta de teste em `accounts` → checar tabela de auditoria de leitura | 1 linha nova registrada |
| 19.13 | carga-real | contagem nas 3 pontas (raw, 2 MVs por `countMerge`) | 10.000.000 em todas |

## ROLLBACK
```bash
# desfazer o perfil (o usuário trio nunca é tocado)
docker exec trio-clickhouse clickhouse-client -u trio --password "$CLICKHOUSE_PASSWORD" \
  -q "DROP USER IF EXISTS analytics_ro; DROP QUOTA IF EXISTS q_analytics_ro"
git checkout -- init/clickhouse/01_schema.sql docker-compose.yml
rm -f docs/SEGURANCA-E-GOVERNANCA.md
```
> **Atenção**: recriar o container do ClickHouse para aplicar `users.d/` é operação com dado
> carregado em volume. Conferir contagem antes e depois — mesmo cuidado da etapa 15, quando
> `prometheus.xml` foi montado em `config.d/` (teste 19.13).

## STATUS
Estado: BLOQUEADA
Premissas assumidas: —
Desvios do plano: —

## FECHAMENTO
- [ ] Critérios atendidos
- [ ] Testes no run_all.sh (bloco `# --- 19 seguranca-e-governanca ---`)
- [ ] run_all.sh sem FAIL
- [ ] ESTADO HERDADO da próxima preenchido
- [ ] Bloco no LOG-EXECUCAO.md
- [ ] Desvio? → atualizar 99-validacao-final.md
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
