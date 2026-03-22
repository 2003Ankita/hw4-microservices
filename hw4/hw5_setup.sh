#!/bin/bash
set -euxo pipefail

PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
ZONE="us-central1-a"

VM_NAME="hw4-web-vm"
SA_NAME="hw4-web-sa"
STATIC_IP_NAME="hw4-web-ip"
FIREWALL_RULE="allow-hw4-web-8080"

# ⚠️ CHANGE THIS TO YOUR HW2 BUCKET
BUCKET_NAME="pagerank-bu-ap178152"
PREFIX="webgraph_v2/"
PORT="8080"

echo "Using project: $PROJECT_ID"

# -----------------------------
# 1️⃣ Create Service Account
# -----------------------------
if ! gcloud iam service-accounts describe "$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="HW4 Web Server SA"
fi

# Logging permission
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/logging.logWriter" --quiet

# Bucket read-only permission
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
  --member="serviceAccount:$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer" --quiet

# -----------------------------
# 2️⃣ Reserve Static IP
# -----------------------------
if ! gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute addresses create "$STATIC_IP_NAME" --region="$REGION"
fi

STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" \
  --region="$REGION" --format="get(address)")

echo "Static IP reserved: $STATIC_IP"

# -----------------------------
# 3️⃣ Firewall Rule
# -----------------------------
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --allow tcp:$PORT \
    --direction INGRESS \
    --source-ranges 0.0.0.0/0 \
    --target-tags hw4-web
fi

# -----------------------------
# 4️⃣ Create VM (cost-safe: e2-micro)
# -----------------------------
if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --machine-type=e2-micro \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --address="$STATIC_IP_NAME" \
    --tags=hw4-web \
    --service-account="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --metadata="BUCKET_NAME=$BUCKET_NAME,PREFIX=$PREFIX,PORT=$PORT" \
    --metadata-from-file startup-script=./startup.sh
fi

echo "-----------------------------------"
echo "Server will be available at:"
echo "http://$STATIC_IP:$PORT/"
echo "-----------------------------------"