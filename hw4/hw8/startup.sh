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

# Project ID from metadata server
PROJECT_ID="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")"

# Pub/Sub topic name
TOPIC_NAME="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/TOPIC_NAME" || true)"
TOPIC_NAME="${TOPIC_NAME:-hw4-forbidden-topic}"

APP_DIR="/opt/hw8-web"
APP_FILE="$APP_DIR/app.py"

apt-get update
apt-get install -y python3-pip python3-venv

mkdir -p "$APP_DIR"

# Write Flask app
cat > "$APP_FILE" << 'PY'
import os
import json
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
TOPIC_NAME = os.environ.get("TOPIC_NAME", "hw4-forbidden-topic")

BANNED = {
    "North Korea", "Iran", "Cuba", "Myanmar", "Iraq",
    "Libya", "Sudan", "Zimbabwe", "Syria"
}

# Retrieve zone from metadata server
def get_zone():
    try:
        metadata_url = "http://metadata.google.internal/computeMetadata/v1/instance/zone"
        headers = {"Metadata-Flavor": "Google"}
        response = requests.get(metadata_url, headers=headers, timeout=2)
        return response.text.split("/")[-1]
    except Exception:
        return "unknown-zone"

ZONE = get_zone()

# Cloud Logging handler
cl = google.cloud.logging.Client()
handler = CloudLoggingHandler(cl)
logger = logging.getLogger("hw8-web")
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
    if request.method != "GET":
        logger.warning(
            "501 not implemented",
            extra={"method": request.method, "path": request.path}
        )
        return Response(
            "not implemented\n",
            status=501,
            mimetype="text/plain",
            headers={"X-Zone": ZONE}
        )

@app.after_request
def add_zone_header(response):
    response.headers["X-Zone"] = ZONE
    return response

@app.get("/")
def root():
    return Response("OK. Try /0.html\n", status=200, mimetype="text/plain")

@app.get("/<path:filename>")
def get_file(filename: str):
    # Banned-country enforcement
    country = (request.headers.get("X-Country") or "").strip()

    if country in BANNED:
        msg = {
            "event": "FORBIDDEN",
            "country": country,
            "path": request.path,
        }

        logger.critical("403 forbidden (banned country)", extra=msg)
        publisher.publish(topic_path, json.dumps(msg).encode("utf-8"))

        return Response(
            "forbidden\n",
            status=403,
            mimetype="text/plain",
            headers={"X-Zone": ZONE}
        )

    obj_name = f"{PREFIX}{filename}" if PREFIX else filename
    blob = bucket.blob(obj_name)

    if not blob.exists():
        logger.warning(
            "404 not found",
            extra={"object": obj_name, "path": request.path}
        )
        return Response(
            "not found\n",
            status=404,
            mimetype="text/plain",
            headers={"X-Zone": ZONE}
        )

    data = blob.download_as_bytes()
    return Response(
        data,
        status=200,
        mimetype="text/html",
        headers={"X-Zone": ZONE}
    )

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
PY

# Create virtual environment and install dependencies
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install \
    flask \
    google-cloud-storage \
    google-cloud-logging \
    google-cloud-pubsub \
    requests

# Create systemd service
cat > /etc/systemd/system/hw8-web.service << EOF
[Unit]
Description=HW8 Web Server
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
systemctl enable hw8-web.service
systemctl restart hw8-web.service
systemctl status hw8-web.service --no-pager || true

touch /var/log/startup_already_done