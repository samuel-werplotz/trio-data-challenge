# accounts.py — geração das 500k contas (S02 não detalha o gerador de accounts
# além do volume; usamos CPF/CNPJ e nomes sintéticos, distribuídos pelas mesmas
# 15 instituições com peso Zipf — consistência com transactions).

import numpy as np

from config import INSTITUTIONS, N_ACCOUNTS
from distributions import INSTITUTION_CODES, INSTITUTION_PROBS

ACCOUNT_TYPES = ["checking", "payment", "escrow"]
ACCOUNT_TYPE_PROBS = [0.70, 0.25, 0.05]
ACCOUNT_STATUSES = ["active", "blocked", "closed"]
ACCOUNT_STATUS_PROBS = [0.92, 0.05, 0.03]

_FIRST_NAMES = [
    "Ana", "Bruno", "Carla", "Diego", "Elaine", "Fábio", "Gabriela", "Hugo",
    "Isabela", "João", "Karina", "Lucas", "Mariana", "Nelson", "Olívia",
    "Pedro", "Queila", "Rafael", "Sofia", "Thiago", "Valentina", "Wagner",
]
_LAST_NAMES = [
    "Silva", "Santos", "Oliveira", "Souza", "Rodrigues", "Ferreira", "Alves",
    "Pereira", "Lima", "Gomes", "Costa", "Ribeiro", "Martins", "Carvalho",
]

_COMPANY_SUFFIXES = ["Comércio", "Serviços", "Indústria", "Tecnologia", "Logística"]
_COMPANY_CORE = ["Alfa", "Beta", "Nova", "Prime", "Sul", "Norte", "Central", "União"]


def _cpf(rng: np.random.Generator) -> str:
    digits = rng.integers(0, 10, size=11)
    return "".join(str(d) for d in digits)


def _cnpj(rng: np.random.Generator) -> str:
    digits = rng.integers(0, 10, size=14)
    return "".join(str(d) for d in digits)


def generate_accounts_batch(rng: np.random.Generator, n: int, start_idx: int):
    """Gera n contas, devolve lista de tuplas na ordem de account_columns()."""
    inst_codes = rng.choice(INSTITUTION_CODES, size=n, p=INSTITUTION_PROBS)
    is_cnpj = rng.random(n) < 0.18  # ~18% pessoa jurídica, resto pessoa física
    account_types = rng.choice(ACCOUNT_TYPES, size=n, p=ACCOUNT_TYPE_PROBS)
    statuses = rng.choice(ACCOUNT_STATUSES, size=n, p=ACCOUNT_STATUS_PROBS)

    rows = []
    for i in range(n):
        account_number = f"{start_idx + i:010d}"
        if is_cnpj[i]:
            doc_type = "cnpj"
            document = _cnpj(rng)
            core = rng.choice(_COMPANY_CORE)
            suffix = rng.choice(_COMPANY_SUFFIXES)
            name = f"{core} {suffix} Ltda"
        else:
            doc_type = "cpf"
            document = _cpf(rng)
            name = f"{rng.choice(_FIRST_NAMES)} {rng.choice(_LAST_NAMES)}"

        rows.append((
            account_number,
            inst_codes[i],
            document,
            doc_type,
            name,
            account_types[i],
            statuses[i],
        ))
    return rows


def account_columns():
    return (
        "account_number", "institution_code", "holder_document",
        "holder_doc_type", "holder_name", "account_type", "status",
    )
