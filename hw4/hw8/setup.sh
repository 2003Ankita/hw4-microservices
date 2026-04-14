#!/bin/bash
set -euxo pipefail

# ==============================
# Configuration Variables
# ==============================
PROJECT_ID=$(gcloud config get-value project)
REGION="us-west1"
ZONE1="us-west1-a"
ZONE2="us-west1-b"

INSTANCE1="hw8-vm-1"
INSTANCE2="hw8-vm-2"

INSTANCE_GROUP1="hw8-ig-a"
INSTANCE_GROUP2="hw8-ig-b"

HEALTH_CHECK="hw8-health-check"
BACKEND_SERVICE="hw8-backend-service"
FORWARDING_RULE="hw8-forwarding-rule"
ADDRESS_NAME="hw8-lb-ip"
FIREWALL_RULE="allow-hw8-http"

BUCKET_NAME="pagerank-bu-ap178152"
PREFIX="webgraph_v2/"
PORT="8080"

echo "Using project: $PROJECT_ID"

# Ensure project is set
if [[ -z "$PROJECT_ID" || "$PROJECT_ID" == "(unset)" ]]; then
  echo "ERROR: Set the project using:"
  echo "gcloud config set project <PROJECT_ID>"
  exit 1
fi

# ==============================
# Enable Required Services
# ==============================
gcloud services enable compute.googleapis.com logging.googleapis.com

# ==============================
# Create Firewall Rule
# ==============================
if ! gcloud compute firewall-rules describe "$FIREWALL_RULE" >/dev/null 2>&1; then
  gcloud compute firewall-rules create "$FIREWALL_RULE" \
    --allow tcp:$PORT \
    --direction INGRESS \
    --source-ranges 0.0.0.0/0 \
    --target-tags=http-server
fi

# ==============================
# Create Virtual Machines
# ==============================
create_vm() {
  local VM_NAME=$1
  local ZONE=$2

  if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" >/dev/null 2>&1; then
    gcloud compute instances create "$VM_NAME" \
      --zone="$ZONE" \
      --machine-type=e2-micro \
      --image-family=debian-12 \
      --image-project=debian-cloud \
      --tags=http-server \
      --scopes=https://www.googleapis.com/auth/cloud-platform \
      --metadata=BUCKET_NAME=$BUCKET_NAME,PREFIX=$PREFIX,PORT=$PORT \
      --metadata-from-file=startup-script=startup.sh
  fi
}

create_vm "$INSTANCE1" "$ZONE1"
create_vm "$INSTANCE2" "$ZONE2"

echo "Waiting for VMs to initialize..."
sleep 90

# ==============================
# Create Health Check
# ==============================
if ! gcloud compute health-checks describe "$HEALTH_CHECK" --region="$REGION" >/dev/null 2>&1; then
  gcloud compute health-checks create tcp "$HEALTH_CHECK" \
    --region="$REGION" \
    --port="$PORT"
fi

# ==============================
# Create Instance Groups
# ==============================
if ! gcloud compute instance-groups unmanaged describe "$INSTANCE_GROUP1" \
  --zone="$ZONE1" >/dev/null 2>&1; then
  gcloud compute instance-groups unmanaged create "$INSTANCE_GROUP1" \
    --zone="$ZONE1"
fi

if ! gcloud compute instance-groups unmanaged describe "$INSTANCE_GROUP2" \
  --zone="$ZONE2" >/dev/null 2>&1; then
  gcloud compute instance-groups unmanaged create "$INSTANCE_GROUP2" \
    --zone="$ZONE2"
fi

gcloud compute instance-groups unmanaged add-instances "$INSTANCE_GROUP1" \
  --instances="$INSTANCE1" \
  --zone="$ZONE1"

gcloud compute instance-groups unmanaged add-instances "$INSTANCE_GROUP2" \
  --instances="$INSTANCE2" \
  --zone="$ZONE2"

gcloud compute instance-groups set-named-ports "$INSTANCE_GROUP1" \
  --named-ports=http:$PORT \
  --zone="$ZONE1"

gcloud compute instance-groups set-named-ports "$INSTANCE_GROUP2" \
  --named-ports=http:$PORT \
  --zone="$ZONE2"

# ==============================
# Reserve Static External IP
# ==============================
if ! gcloud compute addresses describe "$ADDRESS_NAME" \
  --region="$REGION" >/dev/null 2>&1; then
  gcloud compute addresses create "$ADDRESS_NAME" \
    --region="$REGION"
fi

LB_IP=$(gcloud compute addresses describe "$ADDRESS_NAME" \
  --region="$REGION" \
  --format="get(address)")

# ==============================
# Create Backend Service
# ==============================
if ! gcloud compute backend-services describe "$BACKEND_SERVICE" \
  --region="$REGION" >/dev/null 2>&1; then
  gcloud compute backend-services create "$BACKEND_SERVICE" \
    --load-balancing-scheme=EXTERNAL \
    --protocol=TCP \
    --health-checks="$HEALTH_CHECK" \
    --health-checks-region="$REGION" \
    --region="$REGION"
fi

gcloud compute backend-services add-backend "$BACKEND_SERVICE" \
  --instance-group="$INSTANCE_GROUP1" \
  --instance-group-zone="$ZONE1" \
  --region="$REGION"

gcloud compute backend-services add-backend "$BACKEND_SERVICE" \
  --instance-group="$INSTANCE_GROUP2" \
  --instance-group-zone="$ZONE2" \
  --region="$REGION"

# ==============================
# Create Forwarding Rule
# ==============================
if ! gcloud compute forwarding-rules describe "$FORWARDING_RULE" \
  --region="$REGION" >/dev/null 2>&1; then
  gcloud compute forwarding-rules create "$FORWARDING_RULE" \
    --load-balancing-scheme=EXTERNAL \
    --region="$REGION" \
    --ports="$PORT" \
    --address="$ADDRESS_NAME" \
    --backend-service="$BACKEND_SERVICE"
fi

# ==============================
# Output Details
# ==============================
echo "======================================"
echo "HW8 Deployment Completed Successfully!"
echo "Load Balancer IP: $LB_IP"
echo "Test with:"
echo "curl -I http://$LB_IP:$PORT/"
echo "======================================"