#!/bin/bash
set -euxo pipefail

# Run-once lock (startup runs on every boot)
if [ -f /var/log/startup_already_done ]; then
  echo "Startup script already ran once. Skipping."
  exit 0
fi

# Read metadata values passed during VM creation
BUCKET_NAME="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/BUCKET_NAME")"

PREFIX="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/PREFIX" || true)"
PREFIX="${PREFIX:-webgraph_v2/}"

PORT="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/PORT" || true)"
PORT="${PORT:-8080}"

# Project ID from metadata server (recommended)
PROJECT_ID="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")"

# Pub/Sub topic id (can be overridden by instance metadata too if you want)
TOPIC_ID="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/TOPIC_ID" || true)"
TOPIC_ID="${TOPIC_ID:-forbidden-requests}"

APP_DIR="/opt/hw4-web"
APP_FILE="$APP_DIR/app.py"

apt-get update
apt-get install -y python3-pip python3-venv

mkdir -p "$APP_DIR"

# Write Flask app
cat > "$APP_FILE" << 'PY'
import os
import logging
import requests
from flask import Flask, Response, request
from google.cloud import storage
import google.cloud.logging
from google.cloud.logging.handlers import CloudLoggingHandler
from google.cloud import pubsub_v1

BUCKET_NAME = os.environ["BUCKET_NAME"]
PREFIX = os.environ.get("PREFIX", "")
PORT = int(os.environ.get("PORT", "8080"))

PROJECT_ID = os.environ["PROJECT_ID"]
TOPIC_ID = os.environ.get("TOPIC_ID", "forbidden-requests")

BANNED = {
    "North Korea", "Iran", "Cuba", "Myanmar", "Iraq",
    "Libya", "Sudan", "Zimbabwe", "Syria"
}

# Cloud Logging handler
cl = google.cloud.logging.Client()
handler = CloudLoggingHandler(cl)
logger = logging.getLogger("hw4-web")
logger.setLevel(logging.INFO)
logger.addHandler(handler)

# GCS client
storage_client = storage.Client()
bucket = storage_client.bucket(BUCKET_NAME)

# Pub/Sub publisher
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_ID)

app = Flask(__name__)

def client_ip() -> str:
    """
    Tries X-Forwarded-For first (useful if you add a header in testing),
    else uses request.remote_addr.
    """
    xff = request.headers.get("X-Forwarded-For")
    if xff:
        return xff.split(",")[0].strip()
    return request.remote_addr or ""

def ip_to_country_name(ip: str) -> str:
    """
    ipapi returns a country name as plain text, e.g. "United States".
    May return empty / "Undefined" for private IPs.
    """
    try:
        r = requests.get(f"https://ipapi.co/{ip}/country_name/", timeout=2)
        return (r.text or "").strip()
    except Exception:
        return ""

@app.before_request
def reject_non_get():
    # HW4 Point 3: any non-GET method should return 501 + WARNING log
    if request.method != "GET":
        logger.warning(
            "501 not implemented",
            extra={"method": request.method, "path": request.path}
        )
        return Response("not implemented\n", status=501, mimetype="text/plain")

@app.get("/")
def root():
    return Response("OK. Try /0.html\n", status=200, mimetype="text/plain")

@app.get("/<path:filename>")
def get_file(filename: str):
    # ---- Q7 banned-country enforcement (GET requests) ----
    ip = client_ip()
    country = ip_to_country_name(ip)

    if country in BANNED:
        msg = f"FORBIDDEN export-control request from {country} ip={ip} path={request.path}"
        logger.critical(msg, extra={"country": country, "ip": ip, "path": request.path})
        try:
            publisher.publish(topic_path, msg.encode("utf-8"))
        except Exception as e:
            # still return forbidden even if publish fails
            logger.critical(f"PubSub publish failed: {e}", extra={"country": country, "ip": ip, "path": request.path})
        return Response("forbidden\n", status=403, mimetype="text/plain")

    # ---- normal GCS file serving ----
    obj_name = f"{PREFIX}{filename}" if PREFIX else filename
    blob = bucket.blob(obj_name)

    if not blob.exists():
        logger.warning("404 not found", extra={"object": obj_name, "path": request.path})
        return Response("not found\n", status=404, mimetype="text/plain")

    data = blob.download_as_bytes()
    return Response(data, status=200, mimetype="text/html")

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
PY

# Create venv + install deps
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install flask google-cloud-storage google-cloud-logging google-cloud-pubsub requests

# systemd service (auto-start)
cat > /etc/systemd/system/hw4-web.service << EOF
[Unit]
Description=HW4 Web Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=BUCKET_NAME=$BUCKET_NAME
Environment=PREFIX=$PREFIX
Environment=PORT=$PORT
Environment=PROJECT_ID=$PROJECT_ID
Environment=TOPIC_ID=$TOPIC_ID
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python $APP_FILE
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hw4-web.service
systemctl restart hw4-web.service
systemctl status hw4-web.service --no-pager || true

touch /var/log/startup_already_done