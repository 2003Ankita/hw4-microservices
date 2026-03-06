cat > forbidden_startup.sh <<'SH'
#!/bin/bash
set -euxo pipefail

PROJECT_ID="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")"

SUB="$(curl -fsH "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/attributes/SUB" || true)"
SUB="${SUB:-forbidden-requests-sub}"

APP_DIR="/opt/hw4-forbidden"
mkdir -p "$APP_DIR"

apt-get update
apt-get install -y python3-venv

cat > "$APP_DIR/subscriber.py" <<'PY'
import os
import time
from google.cloud import pubsub_v1

project_id = os.environ["PROJECT_ID"]
sub_id = os.environ["SUB_ID"]

subscriber = pubsub_v1.SubscriberClient()
sub_path = subscriber.subscription_path(project_id, sub_id)

def callback(message):
    print("FORBIDDEN REQUEST ALERT:", message.data.decode("utf-8"), flush=True)
    message.ack()

print("Forbidden tracker started. Listening on:", sub_path, flush=True)
subscriber.subscribe(sub_path, callback=callback)

while True:
    time.sleep(60)
PY

python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
"$APP_DIR/venv/bin/pip" install google-cloud-pubsub

cat > /etc/systemd/system/hw4-forbidden.service <<EOF
[Unit]
Description=HW4 Forbidden Tracker (Pub/Sub Subscriber)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=PROJECT_ID=$PROJECT_ID
Environment=SUB_ID=$SUB
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/venv/bin/python $APP_DIR/subscriber.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hw4-forbidden.service
systemctl restart hw4-forbidden.service
systemctl status hw4-forbidden.service --no-pager || true
SH

chmod +x forbidden_startup.sh