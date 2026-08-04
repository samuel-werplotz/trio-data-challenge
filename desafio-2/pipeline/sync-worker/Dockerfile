# sync-worker — pipeline TimescaleDB -> ClickHouse por micro-batch (watermark).
# Substitui o cdc-consumer no caminho principal: CDC via Debezium foi descartado
# porque publish_via_partition_root não funciona sobre hypertable.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY config.py source.py sink.py metrics.py main.py ./

# Métricas Prometheus. sync_last_success_timestamp é a série que detecta o
# incidente SEV-1 do Desafio 3 (pipeline parado) em minutos.
EXPOSE 8001

# -u: sem buffer, para o log aparecer no docker logs em tempo real.
CMD ["python", "-u", "main.py"]
