FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 \
    krb5-user \
    bind9-dnsutils \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY app.py /app/app.py
RUN chmod +x /app/app.py

EXPOSE 8765
CMD ["python3", "/app/app.py"]
