import os
import json
import logging
from flask import Flask, Response, request
from google.cloud import storage
import google.cloud.logging
from google.cloud.logging.handlers import CloudLoggingHandler
from google.cloud import pubsub_v1

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
# Setup logging (works locally + GCP)
# -------------------------------
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("hw4-web")

# -------------------------------
# Try connecting to GCP services
# -------------------------------
GCP_AVAILABLE = True

try:
    # Cloud Logging
    cl = google.cloud.logging.Client()
    handler = CloudLoggingHandler(cl)
    logger.addHandler(handler)

    # GCS
    storage_client = storage.Client()
    bucket = storage_client.bucket(BUCKET_NAME)

    # Pub/Sub
    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(PROJECT_ID, TOPIC_NAME)

except Exception as e:
    print("⚠️ GCP not available (running in local mode):", e)
    GCP_AVAILABLE = False

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

    # ---- banned country logic ----
    country = (request.headers.get("X-Country") or "").strip()

    if country in BANNED:
        msg = {
            "event": "FORBIDDEN",
            "country": country,
            "path": request.path,
        }

        logger.critical("403 forbidden (banned country)", extra=msg)

        if GCP_AVAILABLE:
            publisher.publish(topic_path, json.dumps(msg).encode("utf-8"))

        return Response("forbidden\n", status=403, mimetype="text/plain")

    # ---- LOCAL MODE (no GCP) ----
    if not GCP_AVAILABLE:
        return Response("local test mode\n", status=200, mimetype="text/plain")

    # ---- normal GCS file serving ----
    obj_name = f"{PREFIX}{filename}" if PREFIX else filename
    blob = bucket.blob(obj_name)

    if not blob.exists():
        logger.warning("404 not found", extra={"object": obj_name, "path": request.path})
        return Response("not found\n", status=404, mimetype="text/plain")

    data = blob.download_as_bytes()
    return Response(data, status=200, mimetype="text/html")

# -------------------------------
# Run app
# -------------------------------
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=PORT)