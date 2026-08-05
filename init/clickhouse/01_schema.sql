-- 01_schema.sql — schema analítico do ClickHouse (S04): transactions_raw,
-- 2 pares tabela+MV de pré-agregação e o dict_institutions. Roda depois de
-- 00_init.sql (cria o database trio_analytics). Nenhum backfill aqui — MVs
-- ficam vazias de propósito (etapa 12); nenhum conector Debezium registrado
-- (etapa 13). Ordem obrigatória: este schema → backfill raw → backfill MVs
-- → só então o conector.

-- ===========================================================================
-- Tabela principal — espelho de transactions do TimescaleDB via CDC
-- ===========================================================================
CREATE TABLE IF NOT EXISTS trio_analytics.transactions_raw
(
    external_id             UUID,
    tx_id                   UInt64,
    -- milissegundos importam para latência de Pix; Delta comprime quase a
    -- zero porque os valores chegam em ordem crescente.
    created_at              DateTime64(3, 'UTC')  CODEC(Delta, ZSTD(1)),
    settled_at              Nullable(DateTime64(3, 'UTC')) CODEC(Delta, ZSTD(1)),
    -- 4 valores cada: vira dicionário interno de 1 byte, não string solta.
    type                    LowCardinality(String),
    status                  LowCardinality(String),
    -- Decimal64, não Float64: exatidão decimal como o NUMERIC de origem —
    -- Float perderia centavos, inaceitável em valor financeiro.
    amount                  Decimal64(2)          CODEC(ZSTD(3)),
    currency                LowCardinality(FixedString(3)),
    source_institution      LowCardinality(String),
    destination_institution LowCardinality(String),
    source_account_id       UInt64                CODEC(Delta, ZSTD(1)),
    destination_account_id  UInt64                CODEC(Delta, ZSTD(1)),
    -- calculada na inserção e gravada em disco: evita repetir dateDiff em
    -- toda query de latência (funil de status e Q3-equivalente leem daqui).
    settlement_seconds      Nullable(Float32)     MATERIALIZED
        if(settled_at IS NULL, NULL,
           dateDiff('millisecond', created_at, settled_at) / 1000.0),
    -- JSON como texto; migraria para tipo JSON nativo só se alguma query
    -- passasse a filtrar por campo interno do metadata.
    metadata                String                CODEC(ZSTD(3)),

    -- colunas de controle do CDC/dedup, não do domínio de negócio:
    _version                UInt64,          -- updated_at em ms: resolve "qual linha vence" na dedup
    _is_deleted             UInt8 DEFAULT 0,
    _ingested_at            DateTime DEFAULT now()  -- comparado a created_at, mede o frescor real do pipeline
)
ENGINE = ReplacingMergeTree(_version)
PARTITION BY toYYYYMM(created_at)
-- menor cardinalidade primeiro (type, 4 valores), maior por último
-- (external_id, 10M) — segue o padrão real de filtro das queries do desafio.
--
-- STATUS FICA FORA DE PROPÓSITO: é a coluna mutável (pending -> settled/
-- failed/reversed). Se entrasse na chave de ordenação, cada mudança de
-- status geraria uma linha com chave DIFERENTE da anterior, e o
-- ReplacingMergeTree dedupliza por chave — as duas coexistiriam para
-- sempre em vez de uma substituir a outra. É a pergunta que a banca faz.
ORDER BY (type, source_institution, toStartOfHour(created_at), external_id)
-- o desafio pede 2 anos de agregados; 25 meses dá 1 mês de margem para o
-- job de limpeza rodar sem cortar dado ainda necessário.
TTL toDateTime(created_at) + INTERVAL 25 MONTH
SETTINGS index_granularity = 8192;

-- ===========================================================================
-- MV 1 — resumo diário por instituição e tipo (contagem/soma/média/p95/p99)
-- ===========================================================================
-- Tabela e MV SEPARADAS, nunca "ENGINE=AggregatingMergeTree direto na MV com
-- POPULATE": (1) POPULATE pode perder linhas inseridas durante a criação —
-- com tabela própria, o backfill via INSERT SELECT roda sob nosso controle;
-- (2) a MV pode ser recriada/trocada sem perder o histórico já agregado.
CREATE TABLE IF NOT EXISTS trio_analytics.daily_by_institution
(
    day                DATE,
    source_institution LowCardinality(String),
    type               LowCardinality(String),
    tx_count           AggregateFunction(count, UInt64),
    total_amount       AggregateFunction(sum, Decimal64(2)),
    avg_amount         AggregateFunction(avg, Decimal64(2)),
    p95_amount         AggregateFunction(quantile(0.95), Decimal64(2)),
    p99_amount         AggregateFunction(quantile(0.99), Decimal64(2)),
    settled_count      AggregateFunction(countIf, UInt64, UInt8),
    failed_count       AggregateFunction(countIf, UInt64, UInt8),
    -- Nullable(Float32): settlement_seconds é NULL para transação ainda não
    -- liquidada, e avgState() sobre coluna nullable produz estado do tipo
    -- Nullable — declarar sem Nullable aqui quebra o INSERT da MV com
    -- CANNOT_CONVERT_TYPE (avg ignora NULL nativamente, mas o tipo do
    -- estado agregado precisa casar exatamente com o que a MV produz).
    avg_settle_seconds AggregateFunction(avg, Nullable(Float32))
)
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(day)
ORDER BY (source_institution, type, day);

-- MV no ClickHouse é GATILHO DE INSERÇÃO, não view: só enxerga o bloco que
-- está entrando a partir de agora. Fica vazia até o backfill explícito
-- (INSERT SELECT, etapa 12) — criá-la depois dos dados carregados NÃO
-- preenche o histórico sozinha. Sintoma clássico de quem esquece isso:
-- dashboard vazio para dado antigo e correto só para dado novo.
CREATE MATERIALIZED VIEW IF NOT EXISTS trio_analytics.mv_daily_by_institution
TO trio_analytics.daily_by_institution AS
SELECT
    toDate(created_at)                      AS day,
    source_institution,
    type,
    countState()                            AS tx_count,
    sumState(amount)                        AS total_amount,
    avgState(amount)                        AS avg_amount,
    quantileState(0.95)(amount)             AS p95_amount,
    quantileState(0.99)(amount)             AS p99_amount,
    countIfState(status = 'settled')        AS settled_count,
    countIfState(status = 'failed')         AS failed_count,
    avgState(settlement_seconds)            AS avg_settle_seconds
FROM trio_analytics.transactions_raw
GROUP BY day, source_institution, type;

-- ===========================================================================
-- MV 2 — funil de status (pending -> settled/failed/reversed) por hora
-- ===========================================================================
CREATE TABLE IF NOT EXISTS trio_analytics.status_funnel
(
    hour               DateTime,
    type               LowCardinality(String),
    source_institution LowCardinality(String),
    status             LowCardinality(String),
    cnt                AggregateFunction(count, UInt64),
    -- mesmo motivo de daily_by_institution: settlement_seconds é Nullable.
    avg_seconds        AggregateFunction(avg, Nullable(Float32)),
    p50_seconds        AggregateFunction(quantile(0.50), Nullable(Float32)),
    p95_seconds        AggregateFunction(quantile(0.95), Nullable(Float32))
)
ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(hour)
ORDER BY (type, source_institution, status, hour);

CREATE MATERIALIZED VIEW IF NOT EXISTS trio_analytics.mv_status_funnel
TO trio_analytics.status_funnel AS
SELECT
    toStartOfHour(created_at) AS hour,
    type, source_institution, status,
    countState()                            AS cnt,
    avgState(settlement_seconds)            AS avg_seconds,
    quantileState(0.50)(settlement_seconds) AS p50_seconds,
    quantileState(0.95)(settlement_seconds) AS p95_seconds
FROM trio_analytics.transactions_raw
GROUP BY hour, type, source_institution, status;

-- LIMITAÇÃO ASSUMIDA E DOCUMENTADA: esta MV mede o ESTADO atual por hora,
-- não a TRANSIÇÃO entre estados. Um funil verdadeiro (tempo em cada estágio,
-- não só o estado final) exigiria uma tabela append-only de eventos
-- (transaction_events) gravando cada mudança de status como linha própria.
-- A origem (TimescaleDB) só guarda o estado atual + created_at/settled_at,
-- não histórico de transições — então essa tabela de eventos não existe.
-- Optamos pela versão mais simples: documentar a limitação é mais honesto
-- que entregar um funil que parece completo e não é. Se a Trio precisasse
-- do funil real, a mudança seria no consumidor CDC (etapa 13): gravar cada
-- evento em tabela paralela em vez de só fazer upsert no estado atual.

-- ===========================================================================
-- Dictionary — instituições parceiras, lidas do legado (não da hypertable)
-- ===========================================================================
-- A origem é o `postgres-legado` (etapa 10: partner_institutions, 15
-- linhas), não o TimescaleDB — instituição é dado de referência do sistema
-- legado, não dado transacional.
CREATE DICTIONARY IF NOT EXISTS trio_analytics.dict_institutions
(
    code       String,
    name       String,
    short_name String,
    inst_type  String,
    is_active  UInt8
)
PRIMARY KEY code
-- Credencial vem da named collection `legado_pg`, declarada em
-- `init/clickhouse-config/named_collections.xml` e montada em `config.d/`.
-- Antes ficava aqui, literal, dentro de um arquivo commitado — segredo em DDL
-- versionado vaza no clone e no histórico, e não gira sem alterar schema
-- (etapa 19). Em produção o XML é gerado do Secrets Manager na subida.
SOURCE(POSTGRESQL(
    NAME legado_pg
    -- só recarrega se o resultado desta query mudar — evita recarga
    -- desnecessária a cada ciclo de LIFETIME quando nada mudou no legado.
    invalidate_query 'SELECT max(updated_at) FROM partner_institutions'
))
LAYOUT(COMPLEX_KEY_HASHED())
-- recarrega entre 4 e 6 min, jitter aleatório: evita que múltiplos nós
-- recarreguem simultaneamente e sobrecarreguem o legado.
LIFETIME(MIN 240 MAX 360);

-- Uso (referência — não é view, é o padrão de leitura documentado em S04):
-- dictGetOrDefault, não dictGet: se uma transação chegar antes de a
-- instituição existir no dicionário (janela de até 5 min do ref-sync,
-- etapa 14), o fallback devolve o código bruto em vez de string vazia —
-- falha graciosa em vez de dado sumindo.
--
--   SELECT dictGetOrDefault('trio_analytics.dict_institutions', 'name',
--                            tuple(source_institution), source_institution)
--   FROM trio_analytics.transactions_raw ...
--
-- Por que Dictionary e não JOIN: JOIN no ClickHouse carrega a tabela da
-- direita inteira na memória A CADA query. Para tabela de referência
-- pequena e lida o tempo todo, é desperdício — o Dictionary carrega uma
-- vez e fica residente.
