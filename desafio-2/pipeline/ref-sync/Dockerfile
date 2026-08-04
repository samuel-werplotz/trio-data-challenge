# ref-sync — pipeline de referência: legado -> Dictionary do ClickHouse.
# Batch de 5 min, não CDC: dado de referência muda em semanas e não paga o
# custo de um slot de replicação a mais no legado (D05).
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY config.py metrics.py ref_sync.py ./

# Métricas Prometheus. refsync_dictionary_age_seconds é a série de frescor —
# o que o LIFETIME do Dictionary sozinho não expõe.
EXPOSE 8002

# -u: sem buffer, para o log aparecer no docker logs em tempo real.
CMD ["python", "-u", "ref_sync.py"]
