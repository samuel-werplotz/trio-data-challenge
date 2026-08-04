#!/usr/bin/env python3
# generate_transactions.py — gerador dos 10M de transações sintéticas (S02).
# Ordem: accounts -> transactions (paralelo, COPY BINARY) -> reconciliation -> ANALYZE.
# Onde encaixa: `make seed` roda este arquivo dentro do serviço `seed` do compose.

import argparse
import json
import sys
import time
import uuid
from calendar import monthrange
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from multiprocessing import Process, Queue

import numpy as np
import psycopg

from accounts import account_columns, generate_accounts_batch
from config import (
    BATCH_SIZE,
    MONTHS,
    N_ACCOUNTS,
    N_WORKERS,
    PG_DSN,
    RECONCILIATION_PCT,
    TOTAL_TRANSACTIONS,
)
from distributions import (
    day_weight,
    sample_amount,
    sample_hour,
    sample_institution,
    sample_settlement_latency_s,
    sample_status,
    sample_type,
)

# Feriados nacionais fixos (aproximação suficiente para a distribuição de S02 —
# não precisamos do calendário exato, só do efeito de queda de volume).
_HOLIDAYS_MMDD = {(1, 1), (4, 21), (5, 1), (9, 7), (10, 12), (11, 2), (11, 15), (12, 25)}


def log_progress(worker: int, month: str, rows: int, rate: float, eta_s: float):
    print(json.dumps({
        "ts": datetime.now(timezone.utc).isoformat(),
        "worker": worker, "month": month, "rows": rows,
        "rate_per_s": round(rate, 1), "eta_s": round(eta_s, 1),
    }), flush=True)


def month_range(start: date, months: int):
    """Lista de (ano, mês) contínuos a partir de start, months elementos."""
    result = []
    y, m = start.year, start.month
    for _ in range(months):
        result.append((y, m))
        m += 1
        if m > 12:
            m = 1
            y += 1
    return result


def split_months_by_worker(months_list, n_workers: int):
    """Divide a lista de (ano,mês) em n_workers blocos contínuos — cada worker
    escreve em poucos chunks diários por vez (S02 § Por que dividir por faixa
    de tempo). Divisão aleatória por linha custaria >2h em vez de ~20 min."""
    chunks = np.array_split(np.arange(len(months_list)), n_workers)
    return [[months_list[i] for i in chunk] for chunk in chunks if len(chunk) > 0]


def random_timestamps_for_month(
    rng: np.random.Generator, year: int, month: int, n: int, not_after: datetime | None = None
) -> np.ndarray:
    """Sorteia n timestamps dentro do mês, respeitando peso por dia-da-semana/
    feriado/dia-de-pagamento (S02 § Por dia) e por hora (S02 § Por hora do dia).
    not_after é o teto real (data+hora) para o mês corrente — sem isso o dia de
    hoje sortearia horas à frente do "agora" real, gerando timestamp no futuro."""
    days_in_month = monthrange(year, month)[1]
    day_weights = np.empty(days_in_month)
    for d in range(1, days_in_month + 1):
        wd = date(year, month, d).weekday()
        is_holiday = (month, d) in _HOLIDAYS_MMDD
        day_weights[d - 1] = day_weight(wd, d, is_holiday)
    day_probs = day_weights / day_weights.sum()

    days = rng.choice(np.arange(1, days_in_month + 1), size=n, p=day_probs)
    hours = sample_hour(rng, n)
    minutes = rng.integers(0, 60, size=n)
    seconds = rng.integers(0, 60, size=n)
    micros = rng.integers(0, 1_000_000, size=n)

    ts = np.empty(n, dtype=object)
    for i in range(n):
        candidate = datetime(
            year, month, int(days[i]), int(hours[i]), int(minutes[i]), int(seconds[i]),
            int(micros[i]), tzinfo=timezone.utc,
        )
        # Clipa em not_after: mantém o dia sorteado (preserva o peso de S02
        # § Por dia), só recua a hora quando ela cairia no futuro.
        if not_after is not None and candidate > not_after:
            candidate = not_after - timedelta(seconds=int(rng.integers(1, 3600)))
        ts[i] = candidate
    return ts


def register_enums(conn):
    """psycopg não conhece os ENUMs customizados por padrão; sem registrá-los,
    copy.set_types() não acha 'transaction_status'/'transaction_type' pelo nome
    e o valor cai no dumper de bpchar errado, desalinhando o stream binário
    (ProtocolViolation em coluna arbitrária mais adiante). Devolve as classes
    Python geradas para converter os valores antes do write_row."""
    status_info = psycopg.types.enum.EnumInfo.fetch(conn, "transaction_status")
    psycopg.types.enum.register_enum(status_info, conn)
    type_info = psycopg.types.enum.EnumInfo.fetch(conn, "transaction_type")
    psycopg.types.enum.register_enum(type_info, conn)
    return status_info.enum, type_info.enum


def copy_transactions_batch(cur, rng, created_ts, types, amounts, institutions, statuses, latencies_s, account_ids, StatusEnum, TypeEnum):
    n = len(created_ts)
    # destino sorteado independente da origem (mesma distribuição Zipf) — na
    # prática pode coincidir com a origem em ~1/15 dos casos, aceitável para o
    # volume sintético.
    dest_institutions = rng.choice(institutions, size=n, replace=True) if n else institutions
    src_acc = account_ids
    dst_acc = account_ids[rng.permutation(n)]

    with cur.copy(
        "COPY transactions (external_id, amount, currency, status, type, "
        "source_institution, destination_institution, source_account_id, "
        "destination_account_id, created_at, settled_at, updated_at, metadata) "
        "FROM STDIN (FORMAT BINARY)"
    ) as copy:
        # 'text' explícito para currency: sem isto, psycopg serializa bpchar
        # (CHAR(3)) com o formato binário errado (ver register_enums acima).
        copy.set_types([
            "uuid", "numeric", "text", "transaction_status", "transaction_type",
            "text", "text", "int8", "int8",
            "timestamptz", "timestamptz", "timestamptz", "jsonb",
        ])
        for i in range(n):
            status = statuses[i]
            created_at = created_ts[i]
            if status in ("settled", "reversed"):
                settled_at = created_at + timedelta(seconds=float(latencies_s[i]))
            else:
                # 'failed' e 'pending' não liquidam
                settled_at = None

            # psycopg infere o binário errado para NUMERIC a partir de float puro
            # (falha com "invalid sign in external numeric value") — Decimal
            # via string preserva os 2 casas decimais exatas.
            copy.write_row((
                uuid.uuid4(),
                Decimal(f"{amounts[i]:.2f}"),
                "BRL",
                StatusEnum[status],
                TypeEnum[types[i]],
                institutions[i],
                dest_institutions[i],
                int(src_acc[i]),
                int(dst_acc[i]),
                created_at,
                settled_at,
                created_at,
                psycopg.types.json.Jsonb({}),
            ))


def worker_main(worker_id: int, months_for_worker, total_target: int, out_queue: Queue):
    rng = np.random.default_rng(seed=1000 + worker_id)
    rows_done = 0
    t0 = time.time()

    with psycopg.connect(PG_DSN) as conn:
        StatusEnum, TypeEnum = register_enums(conn)
        with conn.cursor() as cur:
            # TABLESAMPLE SYSTEM amostra por página de disco: com poucas linhas
            # (testes, ou N_ACCOUNTS pequeno) pode devolver 0 por granularidade
            # de bloco. LIMIT direto é seguro aqui — id é gerado sequencialmente
            # e não carrega nenhum viés de distribuição que precisemos preservar.
            cur.execute("SELECT id FROM accounts ORDER BY id LIMIT 200000")
            account_ids = np.array([r[0] for r in cur.fetchall()], dtype=np.int64)
            if len(account_ids) == 0:
                raise RuntimeError("accounts vazio — rode a etapa de contas antes das transações")

        rows_per_month = total_target // len(months_for_worker)
        for idx, (year, month) in enumerate(months_for_worker):
            n_month = rows_per_month if idx < len(months_for_worker) - 1 else (
                total_target - rows_per_month * (len(months_for_worker) - 1)
            )
            written = 0
            while written < n_month:
                n = min(BATCH_SIZE, n_month - written)
                now = datetime.now(timezone.utc)
                not_after = now if (year, month) == (now.year, now.month) else None
                created_ts = random_timestamps_for_month(rng, year, month, n, not_after=not_after)
                types = sample_type(rng, n)
                amounts = sample_amount(rng, types)
                institutions = sample_institution(rng, n)
                statuses = sample_status(rng, institutions)
                # S02: 'pending' só é realista nas últimas 48h — fora dessa
                # janela (praticamente todo o histórico de 12 meses) reclassifica
                # como 'settled', preservando o restante da distribuição.
                is_pending = statuses == "pending"
                is_recent = np.array([
                    (now - ts) <= timedelta(hours=48) for ts in created_ts
                ])
                reclassify = is_pending & ~is_recent
                if reclassify.any():
                    statuses = statuses.copy()
                    statuses[reclassify] = "settled"
                latencies_s = sample_settlement_latency_s(rng, types, institutions)
                acc_idx = rng.integers(0, len(account_ids), size=n)

                with conn.cursor() as cur:
                    copy_transactions_batch(
                        cur, rng, created_ts, types, amounts, institutions, statuses,
                        latencies_s, account_ids[acc_idx], StatusEnum, TypeEnum,
                    )
                conn.commit()

                written += n
                rows_done += n
                elapsed = time.time() - t0
                rate = rows_done / elapsed if elapsed > 0 else 0
                remaining = total_target - rows_done
                eta = remaining / rate if rate > 0 else 0
                log_progress(worker_id, f"{year}-{month:02d}", rows_done, rate, eta)

    out_queue.put((worker_id, rows_done))


def load_accounts():
    print("=== Gerando accounts ===", flush=True)
    t0 = time.time()
    rng = np.random.default_rng(seed=42)
    cols = account_columns()
    col_list = ", ".join(cols)

    with psycopg.connect(PG_DSN) as conn:
        with conn.cursor() as cur:
            written = 0
            while written < N_ACCOUNTS:
                n = min(BATCH_SIZE, N_ACCOUNTS - written)
                rows = generate_accounts_batch(rng, n, start_idx=written)
                with cur.copy(f"COPY accounts ({col_list}) FROM STDIN (FORMAT BINARY)") as copy:
                    for row in rows:
                        copy.write_row(row)
                written += n
        conn.commit()
    print(f"accounts: {N_ACCOUNTS} linhas em {time.time() - t0:.1f}s", flush=True)


def load_reconciliation():
    print("=== Gerando reconciliation_events ===", flush=True)
    t0 = time.time()
    with psycopg.connect(PG_DSN) as conn:
        with conn.cursor() as cur:
            # Amostra RECONCILIATION_PCT das transações liquidadas/revertidas —
            # não faz sentido reconciliar uma transação pendente ou falha.
            #
            # A divergência é um valor ABSOLUTO pequeno (centavos), não um
            # percentual do amount: percentual faria toda TED de R$100k divergir
            # em R$100, e ~86% da tabela cairia no filtro `abs(difference) >
            # 0.01` — o índice parcial de Q2 (S06) perde o sentido se cobre
            # quase tudo. Aqui ~8% das linhas divergem acima de 1 centavo, que
            # é a premissa de seletividade que S06 assume.
            #
            # reconciled_at acompanha a transação (+ atraso de algumas horas),
            # em vez de now() para todas: sem isso o filtro "últimos 30 dias"
            # de Q2 não exclui nada e a exclusão de chunks fica sem efeito.
            cur.execute(
                "INSERT INTO reconciliation_events "
                "(transaction_id, transaction_created_at, external_reference, "
                " event_type, amount_expected, amount_received, reconciled_at) "
                "SELECT id, created_at, external_id::text, "
                "       'settlement', amount, "
                "       CASE WHEN random() < 0.08 "
                "            THEN amount + (round((random() - 0.5) * 1000) / 100.0) "
                "            ELSE amount END, "
                "       created_at + (random() * INTERVAL '8 hours') "
                "FROM transactions "
                "WHERE status IN ('settled', 'reversed') "
                "AND random() < %s",
                (RECONCILIATION_PCT,),
            )
            n = cur.rowcount
        conn.commit()
    print(f"reconciliation_events: {n} linhas em {time.time() - t0:.1f}s", flush=True)


def already_seeded() -> bool:
    with psycopg.connect(PG_DSN) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT finished_at FROM seed_control WHERE id = 1")
            row = cur.fetchone()
            return row is not None and row[0] is not None


def mark_started():
    with psycopg.connect(PG_DSN) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "INSERT INTO seed_control (id, started_at) VALUES (1, now()) "
                "ON CONFLICT (id) DO UPDATE SET started_at = now(), finished_at = NULL"
            )
        conn.commit()


def mark_finished(total_rows: int):
    with psycopg.connect(PG_DSN) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "UPDATE seed_control SET finished_at = now(), total_rows = %s WHERE id = 1",
                (total_rows,),
            )
        conn.commit()


def clear_all():
    with psycopg.connect(PG_DSN) as conn:
        with conn.cursor() as cur:
            cur.execute("TRUNCATE reconciliation_events, transactions, accounts")
            cur.execute("UPDATE seed_control SET started_at = NULL, finished_at = NULL, total_rows = NULL WHERE id = 1")
        conn.commit()


def print_summary(elapsed_s: float, total_rows: int):
    with psycopg.connect(PG_DSN) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT type, round(100.0*count(*)/sum(count(*)) OVER (), 2) "
                "FROM transactions GROUP BY type ORDER BY 2 DESC"
            )
            type_pct = cur.fetchall()
            cur.execute(
                "SELECT status, round(100.0*count(*)/sum(count(*)) OVER (), 2) "
                "FROM transactions GROUP BY status ORDER BY 2 DESC"
            )
            status_pct = cur.fetchall()
            # pg_total_relation_size('transactions') mede só a tabela pai (vazia
            # numa hypertable) — o dado mora nos chunks, precisa somar por fora.
            cur.execute(
                "SELECT pg_size_pretty(sum(pg_total_relation_size(c.chunk_schema||'.'||c.chunk_name))) "
                "FROM timescaledb_information.chunks c WHERE hypertable_name='transactions'"
            )
            size = cur.fetchone()[0]

    mins, secs = divmod(int(elapsed_s), 60)
    print("=" * 60)
    print(f"total: {total_rows:,} linhas".replace(",", "."))
    print(f"tempo: {mins}m{secs:02d}s")
    print(f"taxa média: {total_rows / elapsed_s:,.0f} linhas/s".replace(",", "."))
    print(f"tamanho: transactions {size} | índices 0 (ainda não criados)")
    print("distribuição verificada:")
    print("  " + " | ".join(f"{t} {p}%" for t, p in type_pct))
    print("  " + " | ".join(f"{s} {p}%" for s, p in status_pct))
    print("=" * 60)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true", help="ignora o marcador e regenera do zero")
    args = parser.parse_args()

    if args.force:
        print("--force: limpando tabelas antes de regenerar", flush=True)
        clear_all()
    elif already_seeded():
        print("seed_control.finished_at já preenchido — nada a fazer (use --force para regenerar)", flush=True)
        sys.exit(0)

    mark_started()
    t0 = time.time()

    load_accounts()

    print(f"=== Gerando {TOTAL_TRANSACTIONS:,} transactions com {N_WORKERS} workers ===".replace(",", "."), flush=True)
    # Os MONTHS meses terminam no mês corrente (inclusive) — é o que faz a
    # janela de 'pending' das últimas 48h (S02) cair dentro do dado gerado.
    today = date.today()
    end_month_ordinal = today.year * 12 + (today.month - 1)
    start_month_ordinal = end_month_ordinal - (MONTHS - 1)
    start_month = date(start_month_ordinal // 12, start_month_ordinal % 12 + 1, 1)
    months_list = month_range(start_month, MONTHS)
    per_worker_months = split_months_by_worker(months_list, N_WORKERS)
    per_worker_target = [TOTAL_TRANSACTIONS // len(per_worker_months)] * len(per_worker_months)
    per_worker_target[-1] += TOTAL_TRANSACTIONS - sum(per_worker_target)

    queue: Queue = Queue()
    procs = []
    for wid, (months_for_worker, target) in enumerate(zip(per_worker_months, per_worker_target)):
        p = Process(target=worker_main, args=(wid, months_for_worker, target, queue))
        p.start()
        procs.append(p)

    total_written = 0
    for _ in procs:
        _, rows = queue.get()
        total_written += rows
    for p in procs:
        p.join()

    load_reconciliation()

    print("=== ANALYZE ===", flush=True)
    with psycopg.connect(PG_DSN) as conn:
        conn.execute("ANALYZE transactions, accounts, reconciliation_events")

    mark_finished(total_written)
    elapsed = time.time() - t0
    print_summary(elapsed, total_written)


if __name__ == "__main__":
    main()
