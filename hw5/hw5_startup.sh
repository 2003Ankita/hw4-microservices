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

PROJECT_ID="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")"

TOPIC_NAME="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/TOPIC_NAME" || true)"
TOPIC_NAME="${TOPIC_NAME:-hw4-forbidden-topic}"

DB_NAME="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/DB_NAME")"

DB_USER="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/DB_USER")"

DB_PASSWORD="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/DB_PASSWORD")"

INSTANCE_CONNECTION_NAME="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/INSTANCE_CONNECTION_NAME")"

APP_DIR="/opt/hw5-web"
APP_FILE="$APP_DIR/app.py"

apt-get update
apt-get install -y python3-pip python3-venv postgresql-client

mkdir -p "$APP_DIR"

# Download Cloud SQL Auth Proxy
curl -o /usr/local/bin/cloud-sql-proxy \
  https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.18.3/cloud-sql-proxy.linux.amd64
chmod +x /usr/local/bin/cloud-sql-proxy

# Write Flask app
cat > "$APP_FILE" << 'PY'
import os
import json
import logging
import time
from flask import Flask, Response, request
from google.cloud import storage
import google.cloud.logging
from google.cloud.logging.handlers import CloudLoggingHandler
from google.cloud import pubsub_v1
import psycopg2
from psycopg2.pool import ThreadedConnectionPool

BUCKET_NAME = os.environ["BUCKET_NAME"]
PREFIX = os.environ.get("PREFIX", "")
PORT = int(os.environ.get("PORT", "8080"))

PROJECT_ID = os.environ["PROJECT_ID"]
TOPIC_NAME = os.environ.get("TOPIC_NAME", "hw4-forbidden-topic")

DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]
DB_HOST = "127.0.0.1"
DB_PORT = 5432

BANNED = {
    "North Korea", "Iran", "Cuba", "Myanmar", "Iraq",
    "Libya", "Sudan", "Zimbabwe", "Syria"
}

cl = google.cloud.logging.Client()
handler = CloudLoggingHandler(cl)
logger = logging.getLogger("hw5-web")
logger.setLevel(logging.INFO)
logger.addHandler(handler)

storage_client = storage.Client()
bucket = storage_client.bucket(BUCKET_NAME)

publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_NAME)

db_pool = ThreadedConnectionPool(
    1, 5,
    host=DB_HOST,
    port=DB_PORT,
    dbname=DB_NAME,
    user=DB_USER,
    password=DB_PASSWORD
)

app = Flask(__name__)

def send_text_response(body, status):
    return Response(body, status=status, mimetype="text/plain")

def send_html_response(body, status):
    return Response(body, status=status, mimetype="text/html")
    
def timed_call(fn, *args, **kwargs):
    start = time.perf_counter()
    result = fn(*args, **kwargs)
    elapsed = time.perf_counter() - start
    return result, elapsed

def first_header(*names):
    for name in names:
        value = request.headers.get(name)
        if value is not None and str(value).strip() != "":
            return str(value).strip()
    return None

def parse_age(value):
    if value is None:
        return None
    try:
        return int(value)
    except Exception:
        return None

def extract_request_metadata(filename):
    country = first_header("X-Country", "Country") or "UNKNOWN"
    client_ip = (
        first_header("X-Client-IP", "Client-IP", "X-Forwarded-For")
        or request.remote_addr
        or "UNKNOWN"
    )
    gender = first_header("X-Gender", "Gender")
    age = parse_age(first_header("X-Age", "Age"))
    income = first_header("X-Income", "Income")

    return {
        "country": country,
        "client_ip": client_ip,
        "gender": gender,
        "age": age,
        "income": income,
        "is_banned": country in BANNED,
        "requested_file": filename
    }

def read_file_from_gcs(filename):
    obj_name = f"{PREFIX}{filename}" if PREFIX else filename
    blob = bucket.blob(obj_name)

    if not blob.exists():
        return None, obj_name

    data = blob.download_as_bytes()
    return data, obj_name

def insert_request_log(meta):
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO request_logs
                (country, client_ip, gender, age, income, is_banned, requested_file)
                VALUES (%s, %s, %s, %s, %s, %s, %s)
            """, (
                meta["country"],
                meta["client_ip"],
                meta["gender"],
                meta["age"],
                meta["income"],
                meta["is_banned"],
                meta["requested_file"]
            ))
        conn.commit()
    finally:
        db_pool.putconn(conn)

def insert_error_log(requested_file, error_code):
    conn = db_pool.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute("""
                INSERT INTO error_logs
                (requested_file, error_code)
                VALUES (%s, %s)
            """, (requested_file, error_code))
        conn.commit()
    finally:
        db_pool.putconn(conn)

@app.before_request
def reject_non_get():
    if request.method != "GET":
        requested_file = request.path.lstrip("/") or "ROOT"

        meta, header_time = timed_call(extract_request_metadata, requested_file)

        db_time = 0.0
        try:
            _, t1 = timed_call(insert_request_log, meta)
            _, t2 = timed_call(insert_error_log, requested_file, 501)
            db_time = t1 + t2
        except Exception as e:
            logger.exception(f"DB logging failed for 501: {e}")

        response, response_time = timed_call(send_text_response, "not implemented\n", 501)

        logger.info(
            "timing_metrics",
            extra={
                "path": request.path,
                "status_code": 501,
                "header_extract_seconds": header_time,
                "gcs_read_seconds": 0.0,
                "db_insert_seconds": db_time,
                "response_send_seconds": response_time
            }
        )

        logger.warning(
            "501 not implemented",
            extra={"method": request.method, "path": request.path}
        )
        return response

@app.get("/")
def root():
    meta, header_time = timed_call(extract_request_metadata, "ROOT")

    db_time = 0.0
    try:
        _, db_time = timed_call(insert_request_log, meta)
    except Exception as e:
        logger.exception(f"DB logging failed for root request: {e}")

    response, response_time = timed_call(send_text_response, "OK. Try /0.html\n", 200)

    logger.info(
        "timing_metrics",
        extra={
            "path": request.path,
            "status_code": 200,
            "header_extract_seconds": header_time,
            "gcs_read_seconds": 0.0,
            "db_insert_seconds": db_time,
            "response_send_seconds": response_time
        }
    )

    return response

@app.get("/<path:filename>")
def get_file(filename: str):
    meta, header_time = timed_call(extract_request_metadata, filename)
    country = meta["country"]

    if country in BANNED:
        msg = {
            "event": "FORBIDDEN",
            "country": country,
            "path": request.path,
        }

        db_time = 0.0
        try:
            _, t1 = timed_call(insert_request_log, meta)
            _, t2 = timed_call(insert_error_log, filename, 403)
            db_time = t1 + t2
        except Exception as e:
            logger.exception(f"DB logging failed for 403: {e}")

        response, response_time = timed_call(send_text_response, "forbidden\n", 403)

        logger.info(
            "timing_metrics",
            extra={
                "path": request.path,
                "status_code": 403,
                "header_extract_seconds": header_time,
                "gcs_read_seconds": 0.0,
                "db_insert_seconds": db_time,
                "response_send_seconds": response_time
            }
        )

        logger.critical("403 forbidden (banned country)", extra=msg)
        publisher.publish(topic_path, json.dumps(msg).encode("utf-8"))
        return response

    file_result, gcs_time = timed_call(read_file_from_gcs, filename)
    data, obj_name = file_result

    if data is None:
        db_time = 0.0
        try:
            _, t1 = timed_call(insert_request_log, meta)
            _, t2 = timed_call(insert_error_log, filename, 404)
            db_time = t1 + t2
        except Exception as e:
            logger.exception(f"DB logging failed for 404: {e}")

        response, response_time = timed_call(send_text_response, "not found\n", 404)

        logger.info(
            "timing_metrics",
            extra={
                "path": request.path,
                "status_code": 404,
                "header_extract_seconds": header_time,
                "gcs_read_seconds": gcs_time,
                "db_insert_seconds": db_time,
                "response_send_seconds": response_time
            }
        )

        logger.warning("404 not found", extra={"object": obj_name, "path": request.path})
        return response

    db_time = 0.0
    try:
        _, db_time = timed_call(insert_request_log, meta)
    except Exception as e:
        logger.exception(f"DB logging failed for 200: {e}")

    response, response_time = timed_call(send_html_response, data, 200)

    logger.info(
        "timing_metrics",
        extra={
            "path": request.path,
            "status_code": 200,
            "header_extract_seconds": header_time,
            "gcs_read_seconds": gcs_time,
            "db_insert_seconds": db_time,
            "response_send_seconds": response_time
        }
    )

    return response

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)
PY

# Create venv + install deps
python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install flask google-cloud-storage google-cloud-logging google-cloud-pubsub psycopg2-binary

# Create Cloud SQL Proxy systemd service
cat > /etc/systemd/system/cloud-sql-proxy.service << EOF
[Unit]
Description=Cloud SQL Auth Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloud-sql-proxy $INSTANCE_CONNECTION_NAME --port 5432
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

# Create web app systemd service
cat > /etc/systemd/system/hw5-web.service << EOF
[Unit]
Description=HW5 Web Server
After=network-online.target cloud-sql-proxy.service
Wants=network-online.target cloud-sql-proxy.service

[Service]
Type=simple
Environment=BUCKET_NAME=$BUCKET_NAME
Environment=PREFIX=$PREFIX
Environment=PORT=$PORT
Environment=PROJECT_ID=$PROJECT_ID
Environment=TOPIC_NAME=$TOPIC_NAME
Environment=DB_NAME=$DB_NAME
Environment=DB_USER=$DB_USER
Environment=DB_PASSWORD=$DB_PASSWORD
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python $APP_FILE
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable cloud-sql-proxy.service
systemctl restart cloud-sql-proxy.service
systemctl status cloud-sql-proxy.service --no-pager || true

systemctl enable hw5-web.service
systemctl restart hw5-web.service
systemctl status hw5-web.service --no-pager || true

touch /var/log/startup_already_done