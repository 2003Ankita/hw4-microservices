from flask import Flask, Response, request
from google.cloud import storage
import requests

app = Flask(__name__)

BUCKET_NAME = "pagerank-bu-ap178152"
METADATA_URL = "http://metadata.google.internal/computeMetadata/v1/instance/zone"
METADATA_HEADERS = {"Metadata-Flavor": "Google"}


def get_zone():
    """Fetch the zone of the VM from GCP metadata."""
    try:
        response = requests.get(METADATA_URL, headers=METADATA_HEADERS)
        return response.text.split("/")[-1]
    except Exception:
        return "unknown-zone"


@app.route("/", defaults={"filename": "index.html"}, methods=["GET"])
@app.route("/<path:filename>", methods=["GET"])
def serve_file(filename):
    zone = get_zone()
    storage_client = storage.Client()
    bucket = storage_client.bucket(BUCKET_NAME)
    blob = bucket.blob(filename)

    if not blob.exists():
        return Response(
            "File not found",
            status=404,
            headers={"X-Zone": zone}
        )

    content = blob.download_as_bytes()
    return Response(
        content,
        status=200,
        headers={"X-Zone": zone}
    )


@app.errorhandler(405)
def method_not_allowed(e):
    zone = get_zone()
    return Response(
        "Not Implemented",
        status=501,
        headers={"X-Zone": zone}
    )


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)