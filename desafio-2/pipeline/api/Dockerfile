# api — ClickHouse servindo aplicação (PDF § 3.2 C.5), não só dashboard.
# 3 endpoints de negócio + /health e /metrics.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY config.py db.py main.py ./

EXPOSE 8000

# 1 worker, deliberadamente: o cache é em memória do processo, então cada worker
# extra é mais um cache independente. Com 2 workers, requisições idênticas
# alternam entre processos e a mesma chave é buscada no ClickHouse uma vez por
# worker — o cache de 10s passa a valer menos justamente sob a rajada que ele
# existe para absorver.
#
# O endpoint é I/O-bound (espera o ClickHouse) e o FastAPI é async, então um
# processo atende requisições concorrentes sem serializar. Escalar aqui é
# trabalho de réplica no orquestrador (ECS/Fargate), com cache compartilhado se
# um dia a taxa de acerto justificar — não de multiplicar processos no container.
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
