import os
import json
import logging
from flask import Flask, Response, request
from google.cloud import storage
from google.cloud import pubsub_v1

# -------------------------------
# Config
# -------------------------------
BUCKET_NAME = os.environ.get("BUCKET_NAME", "pagerank-bu-ap178152")
PREFIX = os.environ.get("PREFIX", "")
PORT = int(os.environ.get("PORT", "8080"))

PROJECT_ID = os.environ.get("PROJECT_ID", "sustained-flow-485619-g3")
TOPIC_NAME = os.environ.get("TOPIC_NAME", "hw4-forbidden-topic")

BANNED = {
    "North Korea", "Iran", "Cuba", "Myanmar", "Iraq",
    "Libya", "Sudan", "Zimbabwe", "Syria"
}

# -------------------------------
# Logging
# -------------------------------
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("hw4-web")

# -------------------------------
# GCS setup (optional)
# -------------------------------
try:
    storage_client = storage.Client()
    bucket = storage_client.bucket(BUCKET_NAME)
    GCS_AVAILABLE = True
except Exception as e:
    print("GCS not available:", e)
    GCS_AVAILABLE = False

# -------------------------------
# Pub/Sub setup (REQUIRED)
# -------------------------------
publisher = pubsub_v1.PublisherClient()
topic_path = publisher.topic_path(PROJECT_ID, TOPIC_NAME)

# -------------------------------
# Flask app
# -------------------------------
app = Flask(__name__)

@app.before_request
def reject_non_get():
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

    country = request.headers.get("X-Country", "").strip()
    print("DEBUG COUNTRY:", country)

    # -------------------------------
    # BANNED COUNTRY LOGIC
    # -------------------------------
    if country in BANNED:
        msg = {
            "event": "FORBIDDEN",
            "country": country,
            "path": request.path,
        }

        logger.critical("403 forbidden (banned country)", extra=msg)

        print("🔥 TRYING TO PUBLISH:", msg)

        publisher.publish(
            topic_path,
            json.dumps(msg).encode("utf-8")
        )

        print("✅ MESSAGE SENT")

        return Response("forbidden\n", status=403, mimetype="text/plain")

    # -------------------------------
    # LOCAL MODE (no GCS)
    # -------------------------------
    if not GCS_AVAILABLE:
        return Response("local test mode\n", status=200, mimetype="text/plain")

    # -------------------------------
    # GCS FILE SERVING
    # -------------------------------
    obj_name = f"{PREFIX}{filename}" if PREFIX else filename
    blob = bucket.blob(obj_name)

    if not blob.exists():
        logger.warning("404 not found", extra={"object": obj_name, "path": request.path})
        return Response("not found\n", status=404, mimetype="text/plain")

    data = blob.download_as_bytes()
    return Response(data, status=200, mimetype="text/html")

# -------------------------------
# Run server
# -------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)