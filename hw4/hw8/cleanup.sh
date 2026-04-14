#!/bin/bash
set -euo pipefail

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

echo "Using project: $PROJECT_ID"
echo "Starting cleanup process..."

# ==============================
# 1. Stop Virtual Machines
# ==============================
echo "Stopping VM instances..."
gcloud compute instances stop $INSTANCE1 --zone=$ZONE1 --quiet || true
gcloud compute instances stop $INSTANCE2 --zone=$ZONE2 --quiet || true

# ==============================
# 2. Delete Load Balancer Resources
# ==============================
echo "Deleting forwarding rule..."
gcloud compute forwarding-rules delete $FORWARDING_RULE \
    --region=$REGION --quiet || true

echo "Deleting backend service..."
gcloud compute backend-services delete $BACKEND_SERVICE \
    --region=$REGION --quiet || true

echo "Deleting health check..."
gcloud compute health-checks delete $HEALTH_CHECK \
    --region=$REGION --quiet || true

echo "Releasing static IP..."
gcloud compute addresses delete $ADDRESS_NAME \
    --region=$REGION --quiet || true

# ==============================
# 3. Delete Instance Groups
# ==============================
echo "Deleting instance groups..."
gcloud compute instance-groups unmanaged delete $INSTANCE_GROUP1 \
    --zone=$ZONE1 --quiet || true

gcloud compute instance-groups unmanaged delete $INSTANCE_GROUP2 \
    --zone=$ZONE2 --quiet || true

# ==============================
# 4. Delete Firewall Rule
# ==============================
echo "Deleting firewall rule..."
gcloud compute firewall-rules delete $FIREWALL_RULE \
    --quiet || true

echo "Cleanup completed successfully!"
echo "VMs have been stopped (not deleted)."