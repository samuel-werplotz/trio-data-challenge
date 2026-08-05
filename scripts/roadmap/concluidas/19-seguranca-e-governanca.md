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
Verificado ao fechar as **etapas 17.5 e 18**:
- **Baseline da suíte: 207 pass / 0 fail / 3 skip** (os 3 SKIP são `make`). Cresceu de 186 com os blocos 17.5 (5 testes) e 18 (16 testes).
- **O perfil `analytics_ro` já está prometido em dois documentos publicados** — `docs/DATA-CHAMPIONS.md` § 1 diz como pedi-lo e aponta para `SEGURANCA-E-GOVERNANCA.md` para a matriz; o `SUMARIO-EXECUTIVO.md` promete a matriz de perfis em 30 dias. **Esta etapa é quem cria o perfil de verdade** — hoje o link aponta para um documento que não existe.
- **Os limites que o perfil deve carregar já estão documentados e testados** em `DATA-CHAMPIONS.md` § 5, com as mensagens reais capturadas do cluster: `max_execution_time` (60 s), `max_rows_to_read` (50M), `max_memory_usage` (4 GiB). Os testes `18.11`/`18.11b` provam que armam. **Amarrá-los ao perfil é o passo 2 desta etapa** — hoje são sugestão em documento, aplicados por sessão.
- **`dict_institutions` corrigido e resolvendo 100%** (era 33,55% — ver etapa 17.5). Consequência para o passo 3: ao parametrizar a senha do `SOURCE(POSTGRESQL(...))`, **conferir `dictHas` sobre os 10M de novo**, não só se o Dictionary carrega. Teste `17.5.1` guarda isso.
- **A senha `trio2024` continua em claro** no `docker-compose.yml`, no DDL do Dictionary e nos comandos do `README.md`. Agora aparece também em `run_all.sh` (blocos novos usam `--password trio2024` como os antigos) — parametrizar exige varrer a suíte junto, não só o DDL.
- **Nenhum perfil existe ainda**: usuário `trio` único, sem `users.d/`, sem `ROW POLICY`, sem `QUOTA`. Confirmado nesta etapa.
- **PII segue contida em `accounts` no TimescaleDB**, e agora isso está **declarado** — seção nova no `REPORT.md` e § 6 do guia. A matriz de perfis pode referenciar essa declaração em vez de repeti-la.
- **Cuidado herdado da 17.5**: teste que restaura valor literal reverte correção de dado silenciosamente (`14.4` desfazia o conserto do `001` a cada execução). Ao criar testes de perfil que mexam em usuário ou permissão, **ler o estado antes e restaurar o lido**, nunca um literal.
- Ambiente: 11 containers de pé, 10.000.000 nas 3 pontas do ClickHouse, legado com 480/80.000/50.000/15.

Verificado ao fechar a etapa 16 (segue válido):
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
- [x] `docs/SEGURANCA-E-GOVERNANCA.md` com matriz perfil × objeto completa (6 perfis × 7 objetos), justificando cada acesso a `accounts` — testes `19.1`/`19.14`
- [x] Perfil `analytics_ro` **existe no ClickHouse**, com role, quota e limites amarrados — testes `19.7`/`19.8`/`19.10`
- [x] `analytics_ro` **não** consegue o que a matriz nega: `DROP` e `INSERT` dão `ACCESS_DENIED`, e elevar o próprio limite dá `READONLY` — testes `19.9`/`19.9b`/`19.9c`
- [x] Senha fora do DDL versionado (named collection `legado_pg`), **com o Dictionary resolvendo 100% dos 10M** depois da troca — testes `19.6`/`19.6b`/`19.11`
- [x] Criptografia em trânsito e em repouso nas duas pontas, com **o que está desligado no local declarado e o motivo** — testes `19.4`/`19.5`
- [x] Auditoria de **leitura** de `accounts` implementada e demonstrada: grava com contagem de linhas, exige finalidade, e é append-only — testes `19.12`/`19.12a`/`19.12b`/`19.12c`
- [x] Mapeamento a BCB 4.658 (8 artigos), LGPD (5 requisitos) e PCI-DSS (fora de escopo, declarado) — testes `19.2`/`19.3`
- [x] Usuário `trio` intacto; dado intacto após a recriação do container — teste `19.13`, **227 pass / 0 fail**

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
Estado: CONCLUÍDA

Premissas assumidas:
- **Teste de perfil exercita a negação, não a permissão.** `19.9`/`19.9b`/`19.9c` verificam que `DROP`, `INSERT` e a elevação do próprio limite falham com o código certo. Permissão passa por acidente — um perfil mal configurado que dá acesso a tudo passaria num teste de leitura.
- **`readonly = 1` faz parte do limite, não é extra.** Sem ele o cliente passa `--max_rows_to_read=999999999999` na linha de comando e afrouxa o teto sozinho. Limite que o usuário ajusta é sugestão.
- **O que não dá para implementar honestamente em Docker local vira requisito de produção escrito.** TLS entre containers, KMS no dado vivo e rotação automática estão no § 5 e § 8 com o motivo de não terem sido feitos — mesma decisão do alerta `StorageAlto` na etapa 15, que manteve a expressão de produção em vez de um proxy local que não se pareceria com o real.
- **A matriz é o contrato; `analytics_ro` é a prova.** `pii_reader`, `ops` e `auditor` exigiriam separar credencial de serviço em todos os componentes — mudança de compose e `.env` de 6 serviços, fora do que a etapa pede. Implementar um perfil de verdade demonstra que o modelo aplica.

Desvios do plano:
1. **RBAC via SQL em vez de `users.d/`, e isso eliminou o risco previsto no ROLLBACK.** O compose já traz `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT: 1` e `/var/lib/clickhouse/access/` persiste no volume — usuário criado por SQL sobrevive à recriação do container (confirmado na prática: `analytics_ro` seguiu de pé após o `up -d` da named collection). O passo 2 previa arquivo em `users.d/`, que exigiria recriar o container só para criar usuário.
2. **`CREATE QUOTA ... TO <settings profile>` não existe.** Dá `UNKNOWN_ROLE` — quota se prende a role ou usuário. Corrigido para `TO analytics_reader`.
3. **A sintaxe da named collection foi validada num dicionário descartável antes de tocar no de produção.** Publicar `SOURCE(POSTGRESQL(NAME legado_pg ...))` no DDL versionado sem testar seria repetir o erro da query ilustrativa de S04 (etapa 12), que só quebrou quando alguém rodou. O teste confirmou a resolução (`Bradesco`) e só então o Dictionary real foi trocado.
4. **O Dictionary vivo não acompanhou o arquivo.** Recriar o container **não** reaplica `init/` — ele só roda em volume novo. O `SHOW CREATE DICTIONARY` continuava mostrando a credencial inline enquanto o `.sql` do repositório já estava corrigido. Precisou de `DROP`/`CREATE` explícito para o schema versionado e o estado real coincidirem; sem isso o teste `19.6` passaria (o arquivo está limpo) com o servidor ainda usando o segredo antigo.
5. **`pgaudit` indisponível mudou o desenho da trilha, e o limite ficou declarado.** A extensão não consta de `pg_available_extensions` e trocar a imagem viola a Seção 2. A trilha foi feita com função `SECURITY DEFINER` + gatilho append-only, o que cobre o **caminho auditado** — quem tiver `SELECT` direto em `accounts` (hoje o superusuário `trio`) ainda lê sem rastro. Está no § 4 e no § 8, com as duas pontas que fecham em produção.

## FECHAMENTO
- [x] Critérios atendidos
- [x] Testes no run_all.sh (bloco `# --- 19 seguranca-e-governanca ---`, 20 testes)
- [x] run_all.sh sem FAIL — **227 pass, 0 fail, 3 skip**
- [x] ESTADO HERDADO da próxima (20) preenchido
- [x] Bloco no LOG-EXECUCAO.md
- [x] Desvio? → registrados em `99-validacao-final.md`
- [ ] Commit checkpoint
- [ ] Mover pra concluidas/. Marcar [x] no CLAUDE.md
