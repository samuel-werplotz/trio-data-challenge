"""db.py — pool de conexão com o ClickHouse e cache de resposta com TTL.

As duas práticas que Container-API.md cobra da API estão aqui, isoladas dos
endpoints: o pool (para não reconectar por requisição) e o cache de 10s (para
cem leitores no mesmo minuto custarem uma query, não cem).
"""
import logging
import queue
import threading
import time

import clickhouse_connect

from config import Config

logger = logging.getLogger("db")


class ClickHousePool:
    """Pool simples de clientes clickhouse_connect.

    Não se usa um pool pronto aqui porque o clickhouse_connect já multiplexa
    HTTP internamente; o que falta é limitar a concorrência e reaproveitar o
    handshake. Uma fila de clientes prontos resolve as duas coisas em ~30
    linhas, sem dependência extra.
    """

    def __init__(self, size: int):
        self._pool: queue.Queue = queue.Queue(maxsize=size)
        self._size = size
        self._created = 0
        self._lock = threading.Lock()

    def _new_client(self):
        return clickhouse_connect.get_client(
            host=Config.CLICKHOUSE_HOST,
            port=Config.CLICKHOUSE_PORT,
            username=Config.CLICKHOUSE_USER,
            password=Config.CLICKHOUSE_PASSWORD,
            database=Config.CLICKHOUSE_DATABASE,
            # Teto no servidor: o ClickHouse aborta a query sozinho ao estourar,
            # em vez de continuar processando depois de o cliente desistir.
            settings={"max_execution_time": Config.QUERY_TIMEOUT_SECONDS},
            connect_timeout=Config.QUERY_TIMEOUT_SECONDS,
            send_receive_timeout=Config.QUERY_TIMEOUT_SECONDS,
        )

    def acquire(self, timeout: float = 5.0):
        """Cliente do pool. Cria sob demanda até POOL_SIZE — abrir as 8 conexões
        no boot atrasaria o start sem ganho, já que a carga típica usa 1 ou 2."""
        try:
            return self._pool.get_nowait()
        except queue.Empty:
            pass

        with self._lock:
            if self._created < self._size:
                self._created += 1
                return self._new_client()

        # Pool saturado: espera devolverem um cliente em vez de abrir a nona
        # conexão. É o mecanismo de contrapressão da API.
        return self._pool.get(timeout=timeout)

    def release(self, client, healthy: bool = True):
        """Devolve o cliente. Cliente que falhou não volta para o pool — seria
        reaproveitar um socket possivelmente quebrado."""
        if not healthy:
            with self._lock:
                self._created -= 1
            try:
                client.close()
            except Exception:  # noqa: BLE001 — fechar é best-effort
                pass
            return
        try:
            self._pool.put_nowait(client)
        except queue.Full:
            with self._lock:
                self._created -= 1
            client.close()


class TTLCache:
    """Cache em memória com TTL por chave.

    Processo único e conjunto pequeno de chaves (3 endpoints × poucos
    parâmetros), então um dict com lock basta e não se justifica um Redis —
    que acrescentaria um ponto de falha para guardar 10 segundos de dado.
    """

    def __init__(self, ttl: float):
        self._ttl = ttl
        self._data: dict = {}
        self._lock = threading.Lock()

    def get(self, key):
        with self._lock:
            entry = self._data.get(key)
            if entry is None:
                return None
            expires_at, value = entry
            if time.time() >= expires_at:
                # Expirado: remove na leitura. Sem thread de limpeza — o número
                # de chaves é limitado pelos endpoints, não pelo tráfego.
                del self._data[key]
                return None
            return value

    def set(self, key, value):
        with self._lock:
            self._data[key] = (time.time() + self._ttl, value)

    def clear(self):
        with self._lock:
            self._data.clear()


pool = ClickHousePool(Config.POOL_SIZE)
cache = TTLCache(Config.CACHE_TTL_SECONDS)


def query(sql: str, parameters: dict | None = None):
    """Executa e devolve (linhas, colunas). Toda query da API passa por aqui —
    é o único lugar que toca o pool, então o tratamento de cliente quebrado
    fica em um ponto só."""
    client = pool.acquire()
    healthy = True
    try:
        result = client.query(sql, parameters=parameters or {})
        return result.result_rows, result.column_names
    except Exception:
        healthy = False
        raise
    finally:
        pool.release(client, healthy=healthy)
