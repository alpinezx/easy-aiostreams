FROM python:3.13-slim
# nsenter (util-linux) is how actions run the setup-*.sh scripts on the host itself.
RUN apt-get update \
 && apt-get install -y --no-install-recommends util-linux \
 && rm -rf /var/lib/apt/lists/* \
 && nsenter --version
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app app
COPY web web
# The version this image was built from, so the panel reports what's running, not what's on disk.
COPY VERSION .
ENV PYTHONUNBUFFERED=1
EXPOSE 8080
# No port is published to the host; only Caddy reaches this over the shared Docker network.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--forwarded-allow-ips=*", "--no-server-header"]
