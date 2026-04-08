#!/bin/bash
set -euxo pipefail

PROJECT_ID="sustained-flow-485619-g3"
ZONE="us-central1-a"
SQL_INSTANCE="hw5-db"

echo "Using project: $PROJECT_ID"


echo "Stopping/deleting VMs if they exist..."
gcloud compute instances delete hw5-web-vm --zone="$ZONE" --quiet || true
gcloud compute instances delete hw4-forbidden-vm --zone="$ZONE" --quiet || true

echo "Stopping Cloud SQL instance..."
gcloud sql instances patch "$SQL_INSTANCE" --activation-policy=NEVER --quiet

echo "Done."
echo "VMs removed and database stopped."
