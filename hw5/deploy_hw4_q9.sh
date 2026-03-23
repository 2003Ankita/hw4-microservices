#!/bin/bash
set -euo pipefail

# ========= USER CONFIG =========
PROJECT_ID="${PROJECT_ID:-sustained-flow-485619-g3}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"

BUCKET_NAME="${BUCKET_NAME:-pagerank-bu-ap178152}"
PREFIX="${PREFIX:-webgraph_v2/}"
PORT="${PORT:-8080}"

WEB_VM="${WEB_VM:-hw4-web-vm}"
FORBID_VM="${FORBID_VM:-hw4-forbidden-vm}"

WEB_SA_NAME="${WEB_SA_NAME:-hw4-web-sa}"
FORBID_SA_NAME="${FORBID_SA_NAME:-hw4-forbid-sa}"

STATIC_IP_NAME="${STATIC_IP_NAME:-hw4-web-ip}"
FIREWALL_RULE="${FIREWALL_RULE:-allow-hw4-web-8080}"

TOPIC_NAME="${TOPIC_NAME:-hw4-forbidden-topic}"
SUB_NAME="${SUB_NAME:-hw4-forbidden-sub}"
# ===============================

echo "Using PROJECT_ID=$PROJECT_ID REGION=$REGION ZONE=$ZONE"
gcloud config set project "$PROJECT_ID" >/dev/null

echo "Enabling required APIs..."
gcloud services enable compute.googleapis.com iam.googleapis.com logging.googleapis.com pubsub.googleapis.com >/dev/null

# --- Create service accounts (idempotent) ---
WEB_SA_EMAIL="${WEB_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
FORBID_SA_EMAIL="${FORBID_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Creating service accounts if missing..."
gcloud iam service-accounts describe "$WEB_SA_EMAIL" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$WEB_SA_NAME" --display-name="HW4 Web Server SA"

gcloud iam service-accounts describe "$FORBID_SA_EMAIL" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$FORBID_SA_NAME" --display-name="HW4 Forbidden Reporter SA"

# --- IAM roles (minimal for HW4) ---
# Web:
#   - read bucket objects
#   - write logs
#   - publish to Pub/Sub
# Forbidden service:
#   - write logs (optional but useful)
#   - subscribe to Pub/Sub
echo "Granting IAM roles..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$WEB_SA_EMAIL" \
  --role="roles/logging.logWriter" --quiet >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$WEB_SA_EMAIL" \
  --role="roles/pubsub.publisher" --quiet >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$FORBID_SA_EMAIL" \
  --role="roles/logging.logWriter" --quiet >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$FORBID_SA_EMAIL" \
  --role="roles/pubsub.subscriber" --quiet >/dev/null

# bucket object viewer binding (bucket-level)
echo "Granting bucket read access to WEB service account..."
gcloud storage buckets add-iam-policy-binding "gs://$BUCKET_NAME" \
  --member="serviceAccount:$WEB_SA_EMAIL" \
  --role="roles/storage.objectViewer" --quiet >/dev/null

# --- Pub/Sub topic + subscription (idempotent) ---
echo "Creating Pub/Sub topic/subscription if missing..."
gcloud pubsub topics describe "$TOPIC_NAME" >/dev/null 2>&1 || gcloud pubsub topics create "$TOPIC_NAME" >/dev/null
gcloud pubsub subscriptions describe "$SUB_NAME" >/dev/null 2>&1 || gcloud pubsub subscriptions create "$SUB_NAME" --topic="$TOPIC_NAME" >/dev/null

# --- Reserve static IP (idempotent) ---
echo "Reserving static IP if missing..."
gcloud compute addresses describe "$STATIC_IP_NAME" --region "$REGION" >/dev/null 2>&1 || \
  gcloud compute addresses create "$STATIC_IP_NAME" --region "$REGION" >/dev/null

STATIC_IP="$(gcloud compute addresses describe "$STATIC_IP_NAME" --region "$REGION" --format='value(address)')"
echo "Static IP: $STATIC_IP"

# --- Firewall rule allow TCP:PORT (idempotent) ---
echo "Creating firewall rule if missing..."
gcloud compute firewall-rules describe "$FIREWALL_RULE" >/dev/null 2>&1 || \
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --allow="tcp:$PORT" \
    --direction=INGRESS \
    --source-ranges="0.0.0.0/0" \
    --target-tags="hw4-web" >/dev/null

# --- Create WEB VM (idempotent: delete old, recreate for clean startup) ---
echo "Recreating WEB VM (so startup script runs cleanly)..."
gcloud compute instances delete "$WEB_VM" --zone "$ZONE" -q >/dev/null 2>&1 || true

gcloud compute instances create "$WEB_VM" \
  --zone "$ZONE" \
  --machine-type="e2-micro" \
  --tags="hw4-web" \
  --address="$STATIC_IP" \
  --service-account="$WEB_SA_EMAIL" \
  --scopes="https://www.googleapis.com/auth/cloud-platform" \
  --metadata="BUCKET_NAME=$BUCKET_NAME,PREFIX=$PREFIX,PORT=$PORT,TOPIC_NAME=$TOPIC_NAME" \
  --metadata-from-file="startup-script=./startup_web.sh" >/dev/null

# --- Create FORBIDDEN VM (3rd VM) ---
echo "Recreating FORBIDDEN VM..."
gcloud compute instances delete "$FORBID_VM" --zone "$ZONE" -q >/dev/null 2>&1 || true

gcloud compute instances create "$FORBID_VM" \
  --zone "$ZONE" \
  --machine-type="e2-micro" \
  --service-account="$FORBID_SA_EMAIL" \
  --scopes="https://www.googleapis.com/auth/cloud-platform" \
  --metadata="SUB_NAME=$SUB_NAME,TOPIC_NAME=$TOPIC_NAME" \
  --metadata-from-file="startup-script=./startup_forbidden.sh" >/dev/null

echo ""
echo "DONE."
echo "Web server URL: http://$STATIC_IP:$PORT/"
echo "Forbidden reporter VM: $FORBID_VM"
echo ""
echo "Tip: Check forbidden service output with:"
echo "  gcloud compute ssh $FORBID_VM --zone $ZONE --command 'sudo journalctl -u hw4-forbidden.service -n 50 --no-pager'"