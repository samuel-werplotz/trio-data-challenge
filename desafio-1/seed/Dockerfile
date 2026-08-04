# Dockerfile do serviço `seed` (docker-compose.yml) — gera as 10M transações
# sintéticas de S02 dentro do ambiente Docker, sem depender de Python no host.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["python", "generate_transactions.py"]
