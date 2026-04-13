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

# Pub/Sub topic name (from instance metadata, with default)
TOPIC_NAME="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/TOPIC_NAME" || true)"
TOPIC_NAME="${TOPIC_NAME:-hw4-forbidden-topic}"

APP_DIR="/opt/hw4-web"
APP_FILE="$APP_DIR/app.py"

apt-get update
apt-get install -y python3-pip python3-venv

mkdir -p "$APP_DIR"

# Write Flask app
cat > "$APP_FILE" << 'PY'
import os
import json
import logging
from flask import Flask, Response, request
from google.cloud import storage
import google.cloud.logging
from google.cloud.logging.handlers import CloudLoggingHandler
from google.cloud import pubsub_v1

BUCKET_NAME = os.environ["BUCKET_NAME"]
PREFIX = os.environ.get("PREFIX", "")
PORT = int(os.environ.get("PORT", "8080"))

PROJECT_ID = os.environ["PROJECT_ID"]
TOPIC_NAME = os.environ.get("TOPIC_NAME", "hw4-forbidden-topic")

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
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_NAME)

app = Flask(__name__)

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
    # ---- Q7 banned-country enforcement (deterministic via header) ----
    # For testing: curl -H "X-Country: North Korea" http://IP:8080/0.html
    country = (request.headers.get("X-Country") or "").strip()

    if country in BANNED:
        msg = {
            "event": "FORBIDDEN",
            "country": country,
            "path": request.path,
        }

        # CRITICAL log requirement
        logger.critical("403 forbidden (banned country)", extra=msg)

        # publish to Pub/Sub for service 2
        publisher.publish(topic_path, json.dumps(msg).encode("utf-8"))

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
"$APP_DIR/venv/bin/pip" install flask google-cloud-storage google-cloud-logging google-cloud-pubsub

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
Environment=TOPIC_NAME=$TOPIC_NAME
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