
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

# Cloud Logging handler
try:
    cl = google.cloud.logging.Client()
    handler = CloudLoggingHandler(cl)

    logging.basicConfig(level=logging.INFO)
    logger = logging.getLogger("hw4-web")
    logger.setLevel(logging.INFO)
    logger.addHandler(handler)

    storage_client = storage.Client()
    bucket = storage_client.bucket(BUCKET_NAME)

    publisher = pubsub_v1.PublisherClient()
    topic_path = publisher.topic_path(PROJECT_ID, TOPIC_NAME)

except Exception as e:
    print("Running locally without full GCP setup:", e)

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