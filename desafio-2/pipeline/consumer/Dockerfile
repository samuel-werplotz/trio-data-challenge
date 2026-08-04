# Dockerfile — consumidor CDC (S05). Imagem slim: só runtime, sem toolchain
# de build — librdkafka já vem pré-compilada no wheel do confluent-kafka.
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8001

CMD ["python", "main.py"]
