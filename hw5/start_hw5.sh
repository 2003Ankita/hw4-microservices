#!/bin/bash
set -euxo pipefail

PROJECT_ID="sustained-flow-485619-g3"
REGION="us-central1"
ZONE="us-central1-a"

SQL_INSTANCE="hw5-db"
DB_NAME="hw5logs"
DB_USER="hw5user"
DB_PASSWORD="Hw5StrongPass123!"

echo "Using project: $PROJECT_ID"
PROJECT_ID="sustained-flow-485619-g3"

echo "Enabling required services..."
gcloud services enable \
  sqladmin.googleapis.com \
  compute.googleapis.com \
  pubsub.googleapis.com \
  cloudfunctions.googleapis.com \
  cloudscheduler.googleapis.com \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  eventarc.googleapis.com

echo "Starting Cloud SQL instance..."
gcloud sql instances patch "$SQL_INSTANCE" --activation-policy=ALWAYS --quiet

echo "Deploying/starting web server + forbidden service..."
chmod +x hw5_setup.sh
chmod +x deploy_hw4_q9.sh

./hw5_setup.sh
./deploy_hw4_q9.sh

echo "Done."
echo "Web VM and forbidden-country service deployment completed."
echo "Cloud SQL instance is active."
