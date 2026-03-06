#!/bin/bash
set -euxo pipefail

if [ -f /var/log/startup_already_done ]; then
  echo "Startup script already ran once. Skipping."
  exit 0
fi

SUB_NAME="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/SUB_NAME")"

APP_DIR="/opt/hw4-forbidden"
APP_FILE="$APP_DIR/forbidden.py"

apt-get update
apt-get install -y python3-pip python3-venv

mkdir -p "$APP_DIR"

cat > "$APP_FILE" << 'PY'
import json
from google.cloud import pubsub_v1

subscriber = pubsub_v1.SubscriberClient()
project_id = subscriber.project  # inferred
sub_name = None

# metadata passed in as env var by systemd
import os
SUB_NAME = os.environ["SUB_NAME"]

subscription_path = subscriber.subscription_path(subscriber.project, SUB_NAME)

def callback(message: pubsub_v1.subscriber.message.Message) -> None:
    try:
        payload = message.data.decode("utf-8")
        obj = json.loads(payload)
        country = obj.get("country", "?")
        path = obj.get("path", "?")
        print(f"[FORBIDDEN] Blocked request from banned country={country} path=/{path}", flush=True)
    except Exception:
        print(f"[FORBIDDEN] Blocked request (raw) {message.data!r}", flush=True)
    finally:
        message.ack()

print(f"Listening on {subscription_path}", flush=True)
streaming_pull_future = subscriber.subscribe(subscription_path, callback=callback)
streaming_pull_future.result()
PY

python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install google-cloud-pubsub

cat > /etc/systemd/system/hw4-forbidden.service << EOF
[Unit]
Description=HW4 Forbidden Country Reporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=SUB_NAME=$SUB_NAME
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python $APP_FILE
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hw4-forbidden.service
systemctl restart hw4-forbidden.service
systemctl status hw4-forbidden.service --no-pager || true

touch /var/log/startup_already_done