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

    # Duas leituras por ciclo, e cada uma resolve um problema diferente.
    #
    # 1) RETOMADA EXATA, a partir do par (updated_at, id) já confirmado. É o que
    #    permite continuar de dentro de um timestamp que tem mais linhas que o
    #    lote — o caso do INSERT em massa, em que `now()` grava o mesmo instante
    #    em todas as linhas.
    #
    # 2) OVERLAP, recuando o instante para pegar o COMMIT tardio: updated_at é
    #    gravado no UPDATE, mas a linha só fica visível no COMMIT, e sem o
    #    recuo ela cairia no vão entre dois ciclos.
    #
    # Por que NÃO dá para fazer as duas numa query só: o overlap recua o
    # timestamp, e recuar exige começar do id 0 daquele instante. Aí o LIMIT
    # se esgota nas linhas JÁ escritas e o ciclo nunca alcança as novas — o
    # pipeline trava, escrevendo nada, sem erro no log. Foi assim que 10.000 de
    # 60.000 linhas ficaram inalcançáveis (etapa 20). A retomada vem primeiro
    # justamente porque é ela que garante progresso.
    wm_ts = estado["last_updated_at"]
    wm_id = estado.get("last_id") or 0

    t0 = time.monotonic()
    linhas = source.fetch_window(pg, wm_ts, full=full, watermark_id=wm_id)

    # Só varre o overlap quando a retomada não encheu o lote. Se encheu, há
    # backlog: gastar leitura com o passado atrasaria ainda mais o presente.
    if len(linhas) < Config.BATCH_MAX_ROWS:
        atraso = wm_ts - timedelta(seconds=Config.OVERLAP_SECONDS)
        vistos = {l["id"] for l in linhas}
        for l in source.fetch_window(pg, atraso, full=full, watermark_id=0):
            if l["id"] not in vistos:
                linhas.append(l)
        linhas.sort(key=lambda l: (l["updated_at"], l["id"]))

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
    # A comparação é por TUPLA, igual à do SELECT e à do ORDER BY. Com
    # `updated_at > limite` puro, toda linha que empatasse no timestamp do
    # watermark era descartada — inclusive as que nunca tinham sido escritas,
    # quando o lote anterior cortou no meio daquele instante. Era assim que
    # 10.000 de 60.000 linhas sumiam sem erro (etapa 20).
    limite = (wm_ts, wm_id)
    novas = [l for l in linhas if (l["updated_at"], l["id"]) > limite]
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

    # Watermark = o PAR (updated_at, id) da última linha do lote, não now() e
    # não só o maior updated_at.
    #
    # As linhas vêm ordenadas por (updated_at, id), então a última é exatamente
    # a fronteira do que foi escrito. Guardar só o timestamp funcionava enquanto
    # cada updated_at tinha poucas linhas; num INSERT em massa (`now()` é fixo
    # por statement) todas compartilham o mesmo instante, o LIMIT corta no meio
    # dele e o id é a única coisa que diz onde parar. Ver etapa 20.
    # max() do PAR, não `linhas[-1]`: a varredura de overlap acrescenta linhas
    # antigas ao lote, e mesmo com a reordenação é o maior par que representa a
    # fronteira do que foi confirmado. Retroceder o watermark faria o ciclo
    # seguinte reescrever o que já entrou.
    novo_watermark, novo_id = max((l["updated_at"], l["id"]) for l in linhas)
    source.commit_watermark(pg, novo_watermark, len(convertidas), full=full,
                            new_id=novo_id)

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
