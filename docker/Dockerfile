FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8888 \
    APP_DATA_DIR=/app/data

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY schema.sql .
COPY static ./static

RUN mkdir -p /app/data/invoices /app/data/backups

VOLUME ["/app/data"]

EXPOSE 8888

CMD ["python", "app.py"]
