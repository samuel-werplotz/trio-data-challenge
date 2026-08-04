# distributions.py — as distribuições estatísticas de S02 § As distribuições.
# Cada worker (generate_transactions.py) importa estas funções para sortear
# tipo, valor, hora, instituição, status e latência de cada transação.

import numpy as np

from config import (
    BASE_FAILURE_RATE,
    INSTITUTIONS,
    OUTLIER_FAILURE_RATE,
    OUTLIER_INSTITUTION_CODES,
    OUTLIER_LATENCY_MULTIPLIER,
)

# ---------- tipo de transação ----------
# Log-normal e não uniforme: pagamentos reais se concentram em faixas baixas
# com cauda longa — uniforme faria uma transação de R$4.900 tão comum quanto
# uma de R$15, destruindo o sentido das agregações de valor.
TYPE_WEIGHTS = {"pix": 0.60, "card": 0.22, "ted": 0.10, "boleto": 0.08}
_TYPES = list(TYPE_WEIGHTS.keys())
_TYPE_PROBS = list(TYPE_WEIGHTS.values())

# (mediana, sigma) da log-normal por tipo — sigma calibrado para a faixa de S02
AMOUNT_PARAMS = {
    "pix":    (150.0, 0.9),
    "card":   (90.0, 0.8),
    "ted":    (3_500.0, 1.0),
    "boleto": (800.0, 0.9),
}
AMOUNT_BOUNDS = {
    "pix":    (10.0, 5_000.0),
    "card":   (20.0, 2_000.0),
    "ted":    (500.0, 100_000.0),
    "boleto": (50.0, 20_000.0),
}

# ---------- hora do dia ----------
# Pesos por hora (0-23), dois picos replicando comportamento comercial BR.
HOUR_WEIGHTS = np.array([
    0.15, 0.15, 0.15, 0.15, 0.15, 0.15,   # 00-05h
    0.50, 0.50, 0.50,                      # 06-08h
    1.00, 1.00, 1.00,                      # 09-11h ← pico manhã
    0.65, 0.65,                            # 12-13h
    0.95, 0.95, 0.95,                      # 14-16h ← pico tarde
    0.70, 0.70, 0.70,                      # 17-19h
    0.35, 0.35, 0.35, 0.35,                # 20-23h
])
HOUR_PROBS = HOUR_WEIGHTS / HOUR_WEIGHTS.sum()

# ---------- instituição (Zipf) ----------
# peso_i = 1/(i+1)^1.1 — sem isso as 15 instituições empatariam em ~6,7% cada
# e o ranking "Top 20 instituições" ficaria sem graça.
_ranks = np.arange(len(INSTITUTIONS))
INSTITUTION_WEIGHTS = 1.0 / (_ranks + 1) ** 1.1
INSTITUTION_PROBS = INSTITUTION_WEIGHTS / INSTITUTION_WEIGHTS.sum()
INSTITUTION_CODES = [code for code, _ in INSTITUTIONS]

# ---------- status ----------
STATUS_WEIGHTS = {"settled": 0.94, "failed": 0.035, "pending": 0.02, "reversed": 0.005}
_STATUSES = list(STATUS_WEIGHTS.keys())
_STATUS_PROBS = list(STATUS_WEIGHTS.values())

# ---------- latência de liquidação (segundos), log-normal por tipo ----------
# (mu, sigma) calibrados para os P50/P95 de S02 em log-espaço: mu = ln(P50)
LATENCY_PARAMS = {
    "pix":    (np.log(1.2), 0.6),
    "card":   (np.log(2.5), 0.9),
    "ted":    (np.log(45 * 60), 0.9),
    "boleto": (np.log(18 * 3600), 0.5),
}


def sample_type(rng: np.random.Generator, n: int) -> np.ndarray:
    return rng.choice(_TYPES, size=n, p=_TYPE_PROBS)


def sample_amount(rng: np.random.Generator, types: np.ndarray) -> np.ndarray:
    amounts = np.empty(len(types), dtype=np.float64)
    for t in _TYPES:
        mask = types == t
        n = mask.sum()
        if n == 0:
            continue
        median, sigma = AMOUNT_PARAMS[t]
        mu = np.log(median)
        lo, hi = AMOUNT_BOUNDS[t]
        vals = rng.lognormal(mean=mu, sigma=sigma, size=n)
        amounts[mask] = np.clip(vals, lo, hi)
    return np.round(amounts, 2)


def sample_hour(rng: np.random.Generator, n: int) -> np.ndarray:
    return rng.choice(24, size=n, p=HOUR_PROBS)


def sample_institution(rng: np.random.Generator, n: int) -> np.ndarray:
    return rng.choice(INSTITUTION_CODES, size=n, p=INSTITUTION_PROBS)


def day_weight(weekday: int, day_of_month: int, is_holiday: bool) -> float:
    """weekday: 0=segunda ... 6=domingo (convenção Python datetime)."""
    if is_holiday:
        return 0.3
    if weekday == 5:
        base = 0.45
    elif weekday == 6:
        base = 0.25
    else:
        base = 1.0
    if day_of_month in (5, 20):
        base *= 1.6
    return base


def sample_status(rng: np.random.Generator, institution_codes: np.ndarray) -> np.ndarray:
    """Institutições outlier (S02) têm taxa de falha 8% em vez de 3,5% — o
    restante da massa de probabilidade é redistribuído proporcionalmente."""
    n = len(institution_codes)
    statuses = np.empty(n, dtype=object)
    is_outlier = np.isin(institution_codes, list(OUTLIER_INSTITUTION_CODES))

    for outlier, mask in ((True, is_outlier), (False, ~is_outlier)):
        cnt = mask.sum()
        if cnt == 0:
            continue
        failure_rate = OUTLIER_FAILURE_RATE if outlier else BASE_FAILURE_RATE
        scale = (1.0 - failure_rate) / (1.0 - BASE_FAILURE_RATE)
        probs = {
            "settled": STATUS_WEIGHTS["settled"] * scale,
            "failed": failure_rate,
            "pending": STATUS_WEIGHTS["pending"] * scale,
            "reversed": STATUS_WEIGHTS["reversed"] * scale,
        }
        total = sum(probs.values())
        p = [probs[s] / total for s in _STATUSES]
        statuses[mask] = rng.choice(_STATUSES, size=cnt, p=p)
    return statuses


def sample_settlement_latency_s(
    rng: np.random.Generator, types: np.ndarray, institution_codes: np.ndarray
) -> np.ndarray:
    """Segundos entre created_at e settled_at. Outliers (S02) têm latência 2,5x."""
    latency = np.empty(len(types), dtype=np.float64)
    is_outlier = np.isin(institution_codes, list(OUTLIER_INSTITUTION_CODES))
    for t in _TYPES:
        mask = types == t
        n = mask.sum()
        if n == 0:
            continue
        mu, sigma = LATENCY_PARAMS[t]
        vals = rng.lognormal(mean=mu, sigma=sigma, size=n)
        mult = np.where(is_outlier[mask], OUTLIER_LATENCY_MULTIPLIER, 1.0)
        latency[mask] = vals * mult
    return latency
