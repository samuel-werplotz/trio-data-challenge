-- 02_rbac.sql — perfil de leitura dos Data Champions (etapa 19).
--
-- Encaixe no fluxo: roda no init do ClickHouse, depois do 01_schema.sql (as
-- concessões referenciam as tabelas). Cria o único perfil não-privilegiado do
-- cluster; o usuário `trio` (aplicação, pipeline, backup) não é tocado.
--
-- Por que este arquivo existe: na etapa 19 o RBAC foi criado por SQL ad-hoc e
-- confirmado persistente em `/var/lib/clickhouse/access/`. Persistir no volume
-- NÃO é o mesmo que existir no repositório — num volume novo o perfil
-- simplesmente não nascia, e a suíte reprovou 6 testes na primeira execução do
-- zero (etapa 99). Configuração que só existe no ambiente vivo é configuração
-- que se perde.
--
-- Matriz completa de perfis: docs/SEGURANCA-E-GOVERNANCA.md § 2.

-- Limites do guia do Data Champion (docs/DATA-CHAMPIONS.md § 5) amarrados ao
-- perfil, não sugeridos por sessão. `readonly = 1` é parte do limite: sem ele
-- o cliente passa --max_rows_to_read na linha de comando e afrouxa o próprio
-- teto — limite que o usuário ajusta é sugestão.
CREATE SETTINGS PROFILE IF NOT EXISTS p_analytics_ro SETTINGS
    max_execution_time = 60,
    max_rows_to_read = 50000000,
    max_memory_usage = 4000000000,
    max_bytes_before_external_group_by = 2000000000,
    readonly = 1;

CREATE ROLE IF NOT EXISTS analytics_reader SETTINGS PROFILE p_analytics_ro;

-- Teto por hora. Protege o cluster de laço de notebook (o Hex reexecuta a
-- célula a cada interação) sem atrapalhar trabalho normal.
CREATE QUOTA IF NOT EXISTS q_analytics_ro
    FOR INTERVAL 1 hour MAX queries = 1000, errors = 100, execution_time = 1800
    TO analytics_reader;

-- Leitura das 2 MVs, da raw e do Dictionary. Nada além disso: sem system.*,
-- sem DDL, sem outro banco.
GRANT SELECT  ON trio_analytics.daily_by_institution TO analytics_reader;
GRANT SELECT  ON trio_analytics.status_funnel        TO analytics_reader;
GRANT SELECT  ON trio_analytics.transactions_raw     TO analytics_reader;
GRANT SELECT  ON trio_analytics.dict_institutions    TO analytics_reader;
GRANT dictGet ON trio_analytics.dict_institutions    TO analytics_reader;

-- Senha placeholder deliberada: o nome é o aviso. Em produção a credencial vem
-- do Secrets Manager e é pessoal, não compartilhada (§ 3 do documento de
-- segurança).
CREATE USER IF NOT EXISTS analytics_ro
    IDENTIFIED WITH sha256_password BY 'trocar-em-producao'
    SETTINGS PROFILE p_analytics_ro;
GRANT analytics_reader TO analytics_ro;
ALTER USER analytics_ro DEFAULT ROLE analytics_reader;
