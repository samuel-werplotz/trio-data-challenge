"""main.py — laço do sync-worker: TimescaleDB -> ClickHouse por micro-batch.

Um ciclo é: lê a janela a partir do watermark -> converte -> escreve no
ClickHouse -> só então avança o watermark. Essa ordem é a garantia de
corretude: falha em qualquer ponto antes do último passo faz o próximo ciclo
reler a mesma janela, e a releitura é absorvida pelo ReplacingMergeTree.

Por que micro-batch e não CDC: publish_via_partition_root não funciona sobre
hypertable (relkind='r' — não é tabela particionada nativa do PostgreSQL),
então o Debezium nunca recebe as escritas dos chunks. Diagnóstico completo em
AUDITORIA-E-REPLANEJAMENTO.md § 4.1; micro-batch é opção de primeira classe no
PDF § 4.2 A.1, não plano B.
"""
import logging
import signal
import sys
import time
from datetime import timedelta

import metrics
import sink
import source
from config import Config

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger("main")

_parar = False


def _sinal(signum, _frame):
    """SIGTERM/SIGINT marcam parada e deixam o ciclo corrente terminar. Matar no
    meio de uma escrita não corromperia nada (o watermark não teria avançado),
    mas encerrar limpo evita reprocessar trabalho já feito."""
    global _parar
    logger.info("sinal %s recebido — encerrando após o ciclo atual", signum)
    _parar = True


def executar_ciclo(pg, ch) -> int:
    """Um ciclo completo. Devolve o número de linhas escritas."""
    estado = source.read_state(pg)
    full = source.should_full_scan(estado)

    # O overlap cobre a linha cujo COMMIT só ficou visível depois de a janela
    # anterior ter sido lida: updated_at é gravado no UPDATE, mas a linha só
    # aparece para outra sessão no COMMIT. Sem a sobreposição ela cairia no vão
    # entre dois ciclos e nunca seria vista.
    watermark = estado["last_updated_at"] - timedelta(seconds=Config.OVERLAP_SECONDS)

    t0 = time.monotonic()
    linhas = source.fetch_window(pg, watermark, full=full)
    read_seconds = time.monotonic() - t0
    metrics.record_read(len(linhas))

    if not linhas:
        if full:
            # Sem isto, um full scan vazio se repetiria a cada ciclo.
            source.touch_full_scan(pg)
        return 0

    # A janela relida pelo overlap traz de volta linhas que o ciclo anterior já
    # escreveu. Reescrevê-las seria inofensivo para a corretude (o
    # ReplacingMergeTree deduplica por _version), mas geraria uma parte nova a
    # cada 10s para sempre — custo de merge e de disco sem nenhum ganho.
    # Filtra pelo watermark ANTERIOR: só entra o que é estritamente mais novo.
    # A releitura continua servindo ao seu propósito, que é pegar o commit
    # tardio — esse sim tem updated_at maior que o watermark.
    limite = estado["last_updated_at"]
    novas = [l for l in linhas if l["updated_at"] > limite]
    relidas = len(linhas) - len(novas)
    if relidas:
        # Visível no log: confirma que o overlap está fazendo seu trabalho e
        # quanto ele custa. Se este número for sempre igual ao lote inteiro,
        # o watermark travou e vale investigar.
        logger.debug("overlap releu %d linha(s) já sincronizada(s)", relidas)
    if not novas:
        if full:
            source.touch_full_scan(pg)
        return 0
    linhas = novas

    convertidas, descartadas = [], 0
    for linha in linhas:
        try:
            convertidas.append(source.to_clickhouse_row(linha))
        except Exception as exc:  # noqa: BLE001
            # Falha de forma numa linha (tipo inesperado, campo nulo onde não
            # deveria) não pode derrubar o ciclo inteiro — é o mesmo princípio
            # da DLQ do consumidor CDC. Aqui a origem é um banco tipado, então
            # isto é rede de segurança, não caminho esperado.
            logger.error("linha id=%s descartada: %s", linha.get("id"), exc)
            metrics.record_dlq()
            descartadas += 1

    if not convertidas:
        metrics.record_error("todas_descartadas")
        return 0

    try:
        write_seconds = sink.write_batch(ch, convertidas)
    except sink.WriteFailedError as exc:
        # Destino indisponível mesmo após todo o retry: NÃO avança o watermark.
        # O ciclo seguinte relê exatamente esta janela. Nada se perde.
        logger.critical("escrita falhou após todas as tentativas: %s", exc)
        metrics.record_error("write_exhausted")
        return 0

    # Watermark = maior updated_at do lote, não now(): se o LIMIT cortou a
    # janela no meio, usar now() pularia o que ficou de fora.
    novo_watermark = max(l["updated_at"] for l in linhas)
    source.commit_watermark(pg, novo_watermark, len(convertidas), full=full)

    lag = max(0.0, time.time() - novo_watermark.timestamp())
    metrics.record_cycle(
        kind="full" if full else "incremental",
        n_rows=len(convertidas), read_seconds=read_seconds,
        write_seconds=write_seconds,
        watermark_epoch=novo_watermark.timestamp(), lag=lag,
    )
    logger.info(
        "ciclo %s: %d linhas em %.3fs (leitura %.3fs, escrita %.3fs) "
        "watermark=%s lag=%.1fs%s",
        "full" if full else "inc", len(convertidas),
        read_seconds + write_seconds, read_seconds, write_seconds,
        novo_watermark.isoformat(), lag,
        f" descartadas={descartadas}" if descartadas else "",
    )
    return len(convertidas)


def run():
    signal.signal(signal.SIGTERM, _sinal)
    signal.signal(signal.SIGINT, _sinal)

    pg = source.connect()
    ch = sink.get_client()
    metrics.start(Config.METRICS_PORT)
    logger.info(
        "sync-worker iniciado — ciclo=%.0fs overlap=%ds lote=%d janela=%dd",
        Config.POLL_INTERVAL_SECONDS, Config.OVERLAP_SECONDS,
        Config.BATCH_MAX_ROWS, Config.CREATED_AT_WINDOW_DAYS,
    )

    while not _parar:
        inicio = time.monotonic()
        try:
            escritas = executar_ciclo(pg, ch)
        except Exception as exc:  # noqa: BLE001
            # Erro de infraestrutura no meio do ciclo (conexão caiu, banco
            # reiniciou): reconecta e tenta no ciclo seguinte. O watermark não
            # avançou, então nada se perdeu.
            logger.exception("erro no ciclo — reconectando")
            metrics.record_error("ciclo")
            try:
                pg.close()
            except Exception:  # noqa: BLE001
                pass
            time.sleep(Config.POLL_INTERVAL_SECONDS)
            try:
                pg = source.connect()
                ch = sink.get_client()
            except Exception:  # noqa: BLE001
                logger.error("reconexão falhou — nova tentativa no próximo ciclo")
            continue

        # Lote cheio significa que ainda há fila: emenda o próximo ciclo sem
        # esperar, para drenar o atraso em vez de acumulá-lo.
        if escritas >= Config.BATCH_MAX_ROWS:
            continue

        dormir = Config.POLL_INTERVAL_SECONDS - (time.monotonic() - inicio)
        if dormir > 0 and not _parar:
            time.sleep(dormir)

    pg.close()
    logger.info("sync-worker encerrado")


if __name__ == "__main__":
    try:
        run()
    except Exception:
        logger.exception("sync-worker encerrado por erro não tratado")
        sys.exit(1)
