# Segurança e governança

O cliente é **Instituição de Pagamento autorizada pelo Banco Central**. Isso
muda o padrão: não basta a plataforma funcionar, ela precisa responder *quem
acessou o quê, quando, e sob qual base legal* — e sobreviver a uma fiscalização.

Este documento traz a matriz de perfis, o modelo de criptografia, a trilha de
auditoria de PII e o mapeamento regulatório. O que está **implementado** e o que
é **requisito de produção** está marcado linha a linha; nada aqui é aspiracional
sem dizer que é.

---

## 1. Onde está o dado sensível

A resposta curta é a coisa mais importante deste documento:

> **PII existe em uma única tabela — `accounts`, no TimescaleDB.**
> `transactions` e os 2 CAggs são livres de dado pessoal por desenho (S01), e o
> **ClickHouse inteiro não guarda nenhuma coluna de PII** — verificado por
> varredura de `system.columns` na etapa 16. A transação referencia o titular
> apenas por `source_account_id` (inteiro).

Isso encurta a superfície de auditoria a uma tabela em um banco. O custo dessa
escolha — reconciliação com dados de conta não é respondível no motor analítico
— está declarado em [`desafio-1/REPORT.md`](../desafio-1/REPORT.md) e no
[guia do Data Champion](DATA-CHAMPIONS.md) § 6.

| Categoria | Onde | Colunas |
|---|---|---|
| **PII direto** | `accounts` (TimescaleDB) | `holder_document`, `holder_name`, `holder_doc_type`, `account_number` |
| Pseudonimizado | `transactions`, `transactions_raw` | `source_account_id`, `destination_account_id` (inteiros) |
| Agregado, sem titular | CAggs, `daily_by_institution`, `status_funnel` | — |
| Referência pública | `partner_institutions`, `dict_institutions` | dados institucionais, não pessoais |

**Não há PAN, CVV ou dado de cartão em nenhuma tabela** — ver § 6 (PCI-DSS).

---

## 2. Matriz de perfis

Linha = perfil, coluna = objeto. `—` é ausência de acesso, não acesso restrito.

| Perfil | `accounts` (PII) | `transactions` | CAggs | `transactions_raw` | MVs | `dict_institutions` | Logs de auditoria |
|---|---|---|---|---|---|---|---|
| **`app`** (aplicação) | leitura+escrita | leitura+escrita | leitura | — | — | — | — |
| **`analytics_ro`** (Data Champion) | — | — | — | **leitura** | **leitura** | **leitura** | — |
| **`pii_reader`** (nominal) | **leitura auditada** (§ 4) | leitura | leitura | — | — | — | — |
| **`ops`** (operação/backup) | — | — | — | — | — | — | leitura |
| **`auditor`** | — | — | — | — | — | — | **leitura** |
| `trio` (superusuário atual) | tudo | tudo | tudo | tudo | tudo | tudo | tudo |

**Justificativa dos acessos a `accounts`** — o único objeto que precisa de
justificativa individual:

| Quem | Por quê | Controle |
|---|---|---|
| `app` | Precisa criar e atualizar conta; é o dono do dado | Sem acesso interativo; roda com credencial de serviço |
| `pii_reader` | Suporte e resposta a titular (LGPD art. 18) | Nominal, com finalidade obrigatória e contagem de linhas registrada |
| `analytics_ro` | **Não tem** — e é o ponto | Análise não precisa de titular; o motor analítico é livre de PII |

### O que está implementado

`analytics_ro` **existe no ClickHouse** e foi validado contra o servidor:

```sql
-- perfil, com os limites do guia do Data Champion amarrados ao usuário
CREATE SETTINGS PROFILE p_analytics_ro SETTINGS
    max_execution_time = 60, max_rows_to_read = 50000000,
    max_memory_usage = 4000000000, readonly = 1;
CREATE QUOTA q_analytics_ro FOR INTERVAL 1 hour
    MAX queries = 1000, errors = 100, execution_time = 1800 TO analytics_reader;
CREATE ROLE analytics_reader SETTINGS PROFILE p_analytics_ro;
GRANT SELECT ON trio_analytics.{transactions_raw,daily_by_institution,status_funnel} TO analytics_reader;
```

Comprovado por teste, não por afirmação:

| Verificação | Resultado |
|---|---|
| Lê as MVs e a raw | ✅ 10.000.000 |
| `DROP TABLE` | ❌ `ACCESS_DENIED` |
| `INSERT` | ❌ `ACCESS_DENIED` |
| Tentar **elevar o próprio limite** (`--max_rows_to_read=999999999999`) | ❌ `Cannot modify 'max_rows_to_read' setting in readonly mode (READONLY)` |

Esse último é o que separa limite real de limite sugerido: com `readonly=1` no
perfil, o usuário não consegue afrouxar o próprio teto pelo cliente.

**Os perfis `pii_reader`, `ops` e `auditor` são requisito de produção**, não
implementados aqui: exigiriam separar credenciais de serviço no `app` e no
pipeline, o que muda o compose e o `.env` de todos os componentes. A matriz
acima é o contrato; `analytics_ro` é a prova de que o modelo aplica.

---

## 3. Gestão de segredos

### O que foi corrigido

A senha do PostgreSQL legado estava **literal dentro do DDL versionado**
(`init/clickhouse/01_schema.sql`, no `SOURCE(POSTGRESQL(...))` do Dictionary).
Era o caso mais indefensável: vaza no clone, no diff e no histórico, e não gira
sem alterar schema.

Hoje o DDL referencia uma **named collection**:

```sql
SOURCE(POSTGRESQL(NAME legado_pg invalidate_query '...'))
```

O valor vive em `init/clickhouse-config/named_collections.xml`, montado em
`config.d/`. Validado: o Dictionary resolve **100%** dos 10M após a troca.

> **Honestidade sobre o alcance:** esse XML ainda contém a senha em claro,
> porque o ambiente é Docker local e o `docker-compose.yml` já expõe a mesma
> credencial. O ganho é **arquitetural** — o DDL deixou de ser o portador do
> segredo, e o ponto de injeção passou a existir. Em produção o arquivo é
> gerado do Secrets Manager na subida do container.

### O modelo de produção

| Item | Decisão |
|---|---|
| Onde | AWS Secrets Manager (≈ $3/mês, ver [`CUSTO-AWS.md`](CUSTO-AWS.md)) |
| Rotação | Automática a cada 90 dias, com Lambda de rotação |
| Quem opera | Plataforma; a aplicação nunca vê o valor, só o ARN |
| Impacto no Dictionary ao girar | O `named_collections.xml` é regerado e o container recarregado; o `LIFETIME(240–360s)` faz o Dictionary reconectar sozinho. **Sem alteração de schema** — que era exatamente o problema do modelo anterior |
| `.env` | Fora do versionamento (`.gitignore`); `.env.example` versionado sem valor real |

**O que continua em claro neste repositório, e por quê**: `docker-compose.yml`,
`named_collections.xml` e os comandos de verificação do `README.md` usam
`trio2024`. É credencial de ambiente local descartável, que não existe em
produção. Trocá-la por variável não aumentaria segurança nenhuma aqui e
quebraria o critério de aceite nº 1 (`docker compose up -d` sem configuração
prévia). **Declarado em vez de escondido.**

### Uma chave privada no histórico do git — declarada

A varredura da etapa 21 encontrou `desafio-3/backup/minio-certs/private.key` no
histórico: foi commitada em `f8a0e2e` e retirada do versionamento em `17a90dc`.
**Remover num commit posterior não apaga do histórico** — ela continua
recuperável por `git log`.

| | |
|---|---|
| O que é | Chave de um certificado **autoassinado**, gerado localmente para o MinIO do `docker compose` |
| Onde vale | Só neste ambiente. Não protege nada fora dele e não tem par em produção |
| Risco real | **Nenhum** — não dá acesso a sistema, dado ou conta |
| Por que não reescrevi o histórico | `filter-branch`/`filter-repo` reescreveria os 30 commits e destruiria o rastro do processo, que é evidência de como a entrega foi construída. Trocar um ativo real por um risco nulo é mau negócio |

**Se fosse uma credencial de verdade, a decisão seria a oposta**: rotacionar o
segredo primeiro (o que invalida o que vazou), depois reescrever o histórico, e
tratar como incidente. O critério é o que a chave **abre** — aqui, nada.
`.env` nunca foi commitado, verificado na mesma varredura.

---

## 4. Auditoria de acesso a PII

O projeto registrava o **apagamento** (`lgpd_erasure_log`, etapa 09) e não
registrava a **leitura** — que é a primeira pergunta de uma fiscalização.

### O que foi implementado

`init/timescaledb/06_pii_access_audit.sql`:

| Componente | O que faz |
|---|---|
| `pii_access_log` | Trilha: quando, qual usuário (`current_user` **e** `session_user`), IP do cliente, aplicação, **finalidade**, **linhas devolvidas**, query |
| `read_accounts_audited(purpose, institution, limit)` | Única porta auditada de leitura. `SECURITY DEFINER`: o chamador não precisa de `SELECT` direto em `accounts` |
| Gatilho append-only | `UPDATE`/`DELETE` na trilha são rejeitados |

Comprovado por teste:

| Verificação | Resultado |
|---|---|
| Leitura auditada devolve dado e registra | ✅ 5 linhas lidas, 1 registro com `rows_returned=5` |
| Leitura **sem finalidade declarada** | ❌ `finalidade do acesso é obrigatória (LGPD art. 37)` |
| `DELETE` na trilha | ❌ `pii_access_log é append-only: DELETE não é permitido` |

**Por que a contagem de linhas importa**: uma trilha que só diz "alguém
consultou `accounts`" não distingue o suporte olhando 1 titular de uma
extração de 80.000. `rows_returned` é o que transforma o log em evidência.

**Por que finalidade é obrigatória**: LGPD art. 37 exige registro das operações
de tratamento. Acesso a dado pessoal sem propósito declarado é exatamente o que
não deve conseguir existir.

### O trade-off declarado

**`pgaudit` seria o caminho canônico e não está disponível**: a extensão não
consta de `pg_available_extensions` na imagem fixada, e trocar a imagem violaria
a reprodutibilidade que é requisito do desafio (mesma decisão do `percentile_agg`
na etapa 08).

Consequência honesta: esta trilha cobre o **caminho auditado**. Quem tiver
`SELECT` direto em `accounts` — hoje, o superusuário `trio` — lê sem deixar
rastro. Em produção isso se fecha em duas pontas: (1) `REVOKE SELECT ON accounts`
de todos os perfis exceto `app`, deixando a função como única porta; (2)
`pgaudit` habilitado no parameter group do Aurora, que registra no nível do
servidor e não depende de o chamador cooperar.

---

## 5. Criptografia

| Camada | Hoje (Docker local) | Produção |
|---|---|---|
| **Em repouso — dado vivo** | ❌ volumes Docker sem cifra | EBS/Aurora storage encryption com CMK do KMS; Aurora cifra também snapshots e réplicas |
| **Em repouso — backup** | ✅ SSE-KMS declarado no destino S3 | Mesmo, com CMK dedicada e rotação anual |
| **Em repouso — ClickHouse** | ❌ | EBS encryption; opcionalmente cifra por coluna nas de maior sensibilidade |
| **Em trânsito — app ↔ banco** | ❌ sem TLS entre containers | `sslmode=verify-full` no PostgreSQL/Aurora; ClickHouse com TLS na 9440 |
| **Em trânsito — pipeline** | ❌ rede interna do Docker | Mesmo, dentro da VPC |
| **Em trânsito — Data Champion / Hex** | ❌ | **PrivateLink** (≈ $17/mês), sem passar pela internet |
| **Em trânsito — externo** | ❌ HTTP na API | TLS 1.2+ terminado no ALB, com certificado do ACM |

**Por que nada de TLS foi ligado localmente**: certificado autoassinado entre
containers exigiria distribuir CA para 6 serviços e quebraria o `docker compose
up -d` de um comando (critério de aceite nº 1). A configuração de produção é
declarada aqui em vez de simulada com um TLS que não se pareceria com o real —
mesma decisão do alerta `StorageAlto` na etapa 15.

**A chave é gerenciada pelo cliente (CMK), não pela AWS (chave de serviço)**:
numa IP regulada, poder revogar a chave é o que dá controle efetivo sobre o dado
em repouso.

---

## 6. Mapeamento regulatório

### Resolução BCB nº 4.658/2018 — segurança cibernética e computação em nuvem

| Requisito | O que a plataforma faz | Evidência |
|---|---|---|
| Art. 3º — política de segurança cibernética | Este documento: perfis, cifra, auditoria, classificação de dado | `docs/SEGURANCA-E-GOVERNANCA.md` |
| Art. 3º §1 IV — controle de acesso | Matriz de perfis; `analytics_ro` com menor privilégio e quota | § 2, testes `19.7`–`19.10` |
| Art. 3º §1 V — trilha de auditoria | Leitura de PII e apagamento registrados, trilha append-only | § 4, `06_pii_access_audit.sql` |
| Art. 3º §2 — cifra | Em repouso e em trânsito, com o que falta declarado | § 5 |
| Art. 5º — plano de resposta a incidente | Runbook e árvore de hipóteses SEV-1 | [`incident-response.md`](../desafio-3/incident-response.md), [`runbook.md`](../desafio-3/runbook.md) |
| Art. 6º — continuidade e recuperação | Backup dos 3 bancos, drill com **RTO 22 s / RPO 60 s medidos** | [`backup/README.md`](../desafio-3/backup/README.md) |
| Art. 12 — contratação de nuvem relevante | Região declarada (`us-east-1`), serviços mapeados com custo | [`CUSTO-AWS.md`](CUSTO-AWS.md), `ADR.md` |
| Art. 15 — notificação ao BC | **Não coberto** — é processo institucional, não de plataforma | — |

### LGPD

| Requisito | Onde |
|---|---|
| Art. 18 — direito de eliminação | `lgpd_erasure_log` + `lgpd-erasure-demo.sh`, executado ponta a ponta |
| Art. 37 — registro das operações | § 4, com finalidade obrigatória |
| Art. 46 — medidas de segurança | § 2 e § 5 |
| Minimização | PII em 1 tabela; motor analítico sem dado pessoal (§ 1) |
| Retenção | 90 d no raw, 2 anos nos CAggs — política escrita, desligada aqui por conflito com o dataset de 12 meses (`REPORT.md` § Retenção) |

### PCI-DSS

**A plataforma está fora do escopo de PCI-DSS, e dizer isso explicitamente vale
mais do que omitir.** Não há PAN, CVV, tarja, chip ou qualquer dado de cartão em
nenhuma tabela — as transações são Pix, TED e boleto, identificadas por
`external_id` e por conta interna. Verificável em
`init/timescaledb/01_schema.sql` e `init/clickhouse/01_schema.sql`.

Se cartão entrasse no produto, o que mudaria: tokenização antes da ingestão, PAN
nunca em claro no analítico, segmentação de rede do ambiente de dados de cartão
e varredura trimestral — nada disso está feito, porque nada disso é necessário
hoje.

---

## 7. Retenção da trilha e integridade

| Item | Decisão |
|---|---|
| Retenção da trilha de acesso | **5 anos** — alinhado ao prazo de guarda de registros financeiros; a trilha é pequena (uma linha por acesso a PII) |
| Retenção do log de apagamento | **Permanente** — é a prova de que o direito foi atendido |
| Destino | Bucket S3 **separado**, com Object Lock (WORM) e conta distinta da operacional |
| Integridade local | Gatilho append-only rejeita `UPDATE`/`DELETE` (§ 4) |
| Quem lê | Perfil `auditor`, sem acesso a nenhum dado de negócio |

**Auditoria que o próprio operador pode reescrever não é auditoria.** O gatilho
resolve o acidente e o descuido; ele **não** resolve um superusuário
determinado, que pode removê-lo. É por isso que o destino de produção é uma
conta AWS separada com Object Lock: a garantia real vem de estar fora do
alcance de quem opera o banco, não de um gatilho dentro dele.

---

## 8. O que falta, declarado

Nenhum destes bloqueia a operação; todos bloqueiam uma auditoria completa.

| Lacuna | Por que não foi feito | Onde fecha |
|---|---|---|
| `pii_reader`, `ops`, `auditor` não existem | Exigem separar credenciais de serviço em todos os componentes | Produção; matriz do § 2 é o contrato |
| Superusuário `trio` lê `accounts` sem rastro | Só se fecha com `REVOKE` + `pgaudit`, indisponível na imagem fixada | Aurora com `pgaudit` no parameter group |
| TLS entre containers | Quebraria o `up -d` de um comando | Produção (§ 5) |
| Cifra em repouso do dado vivo | Volume Docker não tem equivalente honesto a KMS | EBS/Aurora encryption (§ 5) |
| Rotação automática de segredo | Não há Secrets Manager local | § 3 |
| MFA e SSO no acesso humano | Fora do escopo da camada de dados | IAM Identity Center |
