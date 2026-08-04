"""ref_sync.py — pipeline de referência: PostgreSQL legado -> Dictionary do ClickHouse.

Laço de 5 minutos. A cada ciclo lê max(updated_at) e count(*) de
partner_institutions no legado; se mudou desde o ciclo anterior, dispara
SYSTEM RELOAD DICTIONARY no ClickHouse e publica a métrica de frescor.

POR QUE BATCH E NÃO CDC (E09 § Por que batch e não CDC / D05)
-------------------------------------------------------------
Dado de referência muda em escala de SEMANAS; a tabela tem ~200 linhas. Uma
transação muda milhares de vezes por segundo, e é lá que o CDC se paga. Aqui
ele custaria um slot de replicação lógica a mais no legado — que é instância
única, sem réplica — em troca de reduzir uma latência de 5 min que ninguém
consome. Um atraso de 5 minutos num cadastro de instituição é irrelevante;
no fluxo transacional seria inaceitável. Usar a mesma ferramenta para os dois
casos confunde sofisticação com adequação.

POR QUE ESTE SCRIPT EXISTE, SE O LIFETIME JÁ RECARREGA SOZINHO
---------------------------------------------------------------
O dict_institutions declara LIFETIME(MIN 240 MAX 360) + invalidate_query, então
o ClickHouse já se recarrega sozinho entre 4 e 6 minutos. O papel deste worker
é mais estreito, e deliberadamente:
  1. Encurtar o tempo até a recarga quando a mudança de fato acontece (o
     LIFETIME é um relógio cego; aqui a recarga é reativa à mudança).
  2. Publicar a métrica de FRESCOR — que o LIFETIME não expõe. Sem ela não há
     como responder "o dado de referência está velho?" no dashboard.
Não é este script que garante a corretude do Dictionary; é a rede de segurança
e o instrumento de medida em cima de um mecanismo que já funciona sozinho.
"""
import logging
import signal
import sys
import time

import clickhouse_connect
import psycopg

import metrics
from config import Config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
logger = logging.getLogger("ref-sync")

# Assinatura da tabela de origem. max(updated_at) sozinho não detecta DELETE
# (a remoção de uma linha não move o máximo), por isso count(*) entra junto:
# o par (max, count) muda em INSERT, UPDATE e DELETE.
_SELECT_SIGNATURE = """
    SELECT count(*)::bigint AS n_rows,
           extract(epoch FROM max(updated_at))::float8 AS max_updated
      FROM {table}
"""

_running = True


def _handle_signal(signum, _frame):
    """SIGTERM do docker stop encerra o laço no fim do ciclo corrente, em vez de
    matar o processo no meio de uma recarga."""
    global _running
    logger.info("sinal %s recebido, encerrando após o ciclo atual", signum)
    _running = False


def _connect_legacy():
    return psycopg.connect(
        host=Config.PG_HOST,
        port=Config.PG_PORT,
        user=Config.PG_USER,
        password=Config.PG_PASSWORD,
        dbname=Config.PG_DATABASE,
        connect_timeout=Config.QUERY_TIMEOUT_SECONDS,
        # Corta a query no servidor, não só no cliente: sem isto uma consulta
        # travada continuaria consumindo backend no legado depois de o cliente
        # ter desistido.
        options=f"-c statement_timeout={Config.QUERY_TIMEOUT_SECONDS * 1000}",
    )


def _connect_clickhouse():
    return clickhouse_connect.get_client(
        host=Config.CLICKHOUSE_HOST,
        port=Config.CLICKHOUSE_PORT,
        username=Config.CLICKHOUSE_USER,
        password=Config.CLICKHOUSE_PASSWORD,
        database=Config.CLICKHOUSE_DATABASE,
    )


def _with_retry(label, fn):
    """Escada exponencial de RETRY_DELAYS_SECONDS. Erro de conexão com o legado
    é transitório com frequência (restart, failover); derrubar o worker por
    isso significaria perder a métrica de frescor justamente quando ela é
    interessante."""
    last_error = None
    for attempt, delay in enumerate([0] + Config.RETRY_DELAYS_SECONDS):
        if delay:
            time.sleep(delay)
        try:
            return fn()
        except Exception as exc:  # noqa: BLE001 — categoria vai para a métrica
            last_error = exc
            logger.warning(
                "%s falhou (tentativa %d/%d): %s",
                label, attempt + 1, len(Config.RETRY_DELAYS_SECONDS) + 1, exc,
            )
    raise last_error


def read_signature():
    """(n_rows, max_updated_epoch) da tabela de origem no legado."""
    def _run():
        with _connect_legacy() as conn, conn.cursor() as cur:
            cur.execute(_SELECT_SIGNATURE.format(table=Config.SOURCE_TABLE))
            n_rows, max_updated = cur.fetchone()
            return int(n_rows), float(max_updated) if max_updated is not None else None

    return _with_retry("leitura do legado", _run)


def reload_dictionary(client):
    """Força a recarga. O ClickHouse recarrega de forma síncrona aqui, então ao
    retornar o Dictionary já responde com o dado novo — é o que permite o teste
    de aceite verificar o valor no ciclo seguinte sem esperar o LIFETIME."""
    def _run():
        client.command(
            f"SYSTEM RELOAD DICTIONARY {Config.CLICKHOUSE_DATABASE}.{Config.DICTIONARY}"
        )

    _with_retry("reload do dictionary", _run)
    metrics.record_reload()


def dictionary_row_count(client) -> int | None:
    """Linhas carregadas no Dictionary, lidas de system.dictionaries. Serve de
    confirmação independente: se o legado tem 200 linhas e o Dictionary reporta
    outro número, a recarga não pegou o que se esperava."""
    try:
        result = client.query(
            "SELECT element_count FROM system.dictionaries "
            "WHERE database = %(db)s AND name = %(name)s",
            parameters={"db": Config.CLICKHOUSE_DATABASE, "name": Config.DICTIONARY},
        )
        return int(result.result_rows[0][0]) if result.result_rows else None
    except Exception as exc:  # noqa: BLE001 — diagnóstico, não corretude
        logger.warning("não foi possível ler element_count: %s", exc)
        return None


def run_cycle(client, last_signature):
    """Um ciclo: lê a assinatura do legado, recarrega o Dictionary se mudou,
    publica frescor. Devolve a assinatura lida, que vira a base de comparação
    do ciclo seguinte."""
    started = time.time()
    signature = read_signature()
    n_rows, max_updated = signature

    changed = signature != last_signature
    # Primeiro ciclo após o boot: last_signature é None e `changed` é True, então
    # sempre há uma recarga inicial. É intencional — o worker não tem como saber
    # o que aconteceu no legado enquanto esteve fora do ar.
    if changed:
        logger.info(
            "mudança detectada no legado (linhas=%s, max_updated=%s) — recarregando %s",
            n_rows, max_updated, Config.DICTIONARY,
        )
        reload_dictionary(client)
        outcome = "reloaded"
    else:
        outcome = "unchanged"

    # Frescor medido a partir do max(updated_at) já refletido no Dictionary.
    # Cresce sozinho entre mudanças — é o comportamento correto: mede a idade
    # do dado, não a do último ciclo.
    age = (time.time() - max_updated) if max_updated is not None else None

    duration = time.time() - started
    metrics.record_cycle(outcome, duration, age, n_rows)

    element_count = dictionary_row_count(client)
    logger.info(
        "ciclo %s em %.3fs · legado=%s linhas · dictionary=%s elementos · frescor=%s",
        outcome, duration, n_rows, element_count,
        f"{age:.0f}s" if age is not None else "n/d",
    )
    return signature


def main():
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    metrics.start(Config.METRICS_PORT)
    logger.info(
        "ref-sync iniciado · %s.%s <- %s@%s/%s · ciclo de %.0fs",
        Config.CLICKHOUSE_DATABASE, Config.DICTIONARY, Config.SOURCE_TABLE,
        Config.PG_HOST, Config.PG_DATABASE, Config.POLL_INTERVAL_SECONDS,
    )

    client = _connect_clickhouse()
    last_signature = None

    while _running:
        cycle_started = time.time()
        try:
            last_signature = run_cycle(client, last_signature)
        except Exception as exc:  # noqa: BLE001 — laço não pode morrer
            metrics.record_error(type(exc).__name__)
            logger.error("ciclo falhou: %s", exc, exc_info=True)
            # Reconecta no próximo ciclo: se o erro foi na conexão com o
            # ClickHouse, insistir no mesmo client não resolveria.
            try:
                client = _connect_clickhouse()
            except Exception:  # noqa: BLE001
                logger.error("reconexão ao ClickHouse falhou, tentando no próximo ciclo")

        # Desconta o tempo do ciclo do intervalo: o período fica de 5 min
        # medido de início a início, não 5 min + duração.
        elapsed = time.time() - cycle_started
        remaining = max(0.0, Config.POLL_INTERVAL_SECONDS - elapsed)
        # Sono fatiado para o SIGTERM ser atendido em ~1s e não em até 5 min.
        while remaining > 0 and _running:
            time.sleep(min(1.0, remaining))
            remaining -= 1.0

    logger.info("ref-sync encerrado")
    return 0


if __name__ == "__main__":
    sys.exit(main())
