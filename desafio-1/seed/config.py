# config.py — parâmetros do gerador, literais de S02 § Parâmetros.
# Onde encaixa: importado por generate_transactions.py e distributions.py.

import os

TOTAL_TRANSACTIONS = 10_000_000
MONTHS = 12
N_ACCOUNTS = 500_000
N_INSTITUTIONS = 15
BATCH_SIZE = 50_000      # linhas por COPY
N_WORKERS = 6            # deixa núcleos livres para o próprio Postgres, que ingere
RECONCILIATION_PCT = 0.15

# Conexão via variáveis de ambiente do compose (S08 x-common-env)
PG_DSN = (
    f"host={os.environ.get('PGHOST', 'timescaledb')} "
    f"port={os.environ.get('PGPORT', '5432')} "
    f"dbname={os.environ.get('PGDATABASE', 'trio_transactions')} "
    f"user={os.environ.get('POSTGRES_USER', 'trio')} "
    f"password={os.environ.get('POSTGRES_PASSWORD', 'trio2024')}"
)

# (código, nome) — ordem define o rank usado no peso Zipf abaixo
INSTITUTIONS = [
    ("001", "Banco do Brasil"),   ("237", "Bradesco"),
    ("341", "Itaú Unibanco"),     ("104", "Caixa Econômica"),
    ("033", "Santander"),         ("260", "Nu Pagamentos"),
    ("077", "Banco Inter"),       ("336", "Banco C6"),
    ("212", "Banco Original"),    ("380", "PicPay"),
    ("323", "Mercado Pago"),      ("290", "PagSeguro"),
    ("136", "Unicred"),           ("756", "Sicoob"),
    ("748", "Sicredi"),
]

# Duas instituições da cauda recebem multiplicador de latência 2,5x e taxa de
# falha 8% (vs 3,5% média) — cria outliers reais para os dashboards por instituição.
OUTLIER_INSTITUTION_CODES = {"756", "748"}
OUTLIER_LATENCY_MULTIPLIER = 2.5
OUTLIER_FAILURE_RATE = 0.08
BASE_FAILURE_RATE = 0.035
