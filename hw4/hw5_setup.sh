#!/bin/bash
set -euxo pipefail

PROJECT_ID=$(gcloud config get-value project)
REGION="us-central1"
ZONE="us-central1-b"

VM_NAME="hw5-web-vm"
SA_NAME="hw5-web-sa"
STATIC_IP_NAME="hw5-web-ip"
FIREWALL_RULE="allow-hw5-web-8080"

BUCKET_NAME="pagerank-bu-ap178152"
PREFIX="webgraph_v2/"
PORT="8080"

SQL_INSTANCE="hw5-db"
DB_NAME="hw5logs"
DB_USER="hw5user"
DB_PASSWORD="Hw5StrongPass123!"
INSTANCE_CONNECTION_NAME=$(gcloud sql instances describe "$SQL_INSTANCE" --format="value(connectionName)")
TOPIC_NAME="hw4-forbidden-topic"

echo "Using project: $PROJECT_ID"

if ! gcloud iam service-accounts describe "$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="HW5 Web Server SA"
fi

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/logging.logWriter" --quiet

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/cloudsql.client" --quiet

gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
  --member="serviceAccount:$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/storage.objectViewer" --quiet

if ! gcloud compute addresses describe "$STATIC_IP_NAME" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute addresses create "$STATIC_IP_NAME" --region="$REGION"
fi

STATIC_IP=$(gcloud compute addresses describe "$STATIC_IP_NAME" \
  --region="$REGION" --format="get(address)")

echo "Static IP reserved: $STATIC_IP"

if ! gcloud compute firewall-rules describe "$FIREWALL_RULE" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --allow tcp:$PORT \
    --direction INGRESS \
    --source-ranges 0.0.0.0/0 \
    --target-tags hw5-web
fi

if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
  gcloud compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --machine-type=e2-standard-2  \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --address="$STATIC_IP_NAME" \
    --tags=hw5-web \
    --service-account="$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --scopes=https://www.googleapis.com/auth/cloud-platform \
    --metadata="BUCKET_NAME=$BUCKET_NAME,PREFIX=$PREFIX,PORT=$PORT,DB_NAME=$DB_NAME,DB_USER=$DB_USER,DB_PASSWORD=$DB_PASSWORD,INSTANCE_CONNECTION_NAME=$INSTANCE_CONNECTION_NAME,TOPIC_NAME=$TOPIC_NAME" \
    --metadata-from-file startup-script=./hw5_startup.sh
fi

echo "-----------------------------------"
echo "Server will be available at:"
echo "http://$STATIC_IP:$PORT/"
echo "-----------------------------------"