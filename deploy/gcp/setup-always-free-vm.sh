#!/usr/bin/env bash
# ==============================================================================
# MicroBin Always-Free VM & GCP Infrastructure Provisioning Script
# (Cloudflare Zero Trust Tunnel + Keyless GitHub OIDC Integration)
# ==============================================================================
# This script provisions:
#   1. Required Google Cloud APIs
#   2. Artifact Registry repository for Distroless MicroBin images
#   3. Deployment Service Account & IAM Roles
#   4. Workload Identity Federation (WIF) Pool & Provider for keyless CI/CD
#   5. GCP Always-Free e2-micro VM (0 open public inbound ports!)
# ==============================================================================

set -euo pipefail

# Configuration Defaults (Always-Free Eligible)
DEFAULT_REGION="us-east1"
DEFAULT_ZONE="us-east1-b"
VM_NAME="microbin-free-tier"
GAR_REPO="microbin-repo"
SA_NAME="microbin-deployer"
POOL_NAME="github-pool"
PROVIDER_NAME="github-provider"

echo "=========================================================================="
echo "    MicroBin GCP Always-Free Infrastructure Setup (Cloudflare Tunnel)    "
echo "=========================================================================="

# Check gcloud is installed and authenticated
if ! command -v gcloud &> /dev/null; then
  echo "Error: Google Cloud SDK (gcloud) is not installed."
  echo "Please install it from https://cloud.google.com/sdk/docs/install and run 'gcloud auth login'."
  exit 1
fi

PROJECT_ID=$(gcloud config get-value project 2>/dev/null || true)
if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
  read -rp "Enter your GCP Project ID: " PROJECT_ID
  gcloud config set project "$PROJECT_ID"
else
  echo "Using current GCP Project: $PROJECT_ID"
fi

read -rp "Enter GCP Region [default: $DEFAULT_REGION]: " REGION
REGION=${REGION:-$DEFAULT_REGION}

read -rp "Enter GCP Zone [default: $DEFAULT_ZONE]: " ZONE
ZONE=${ZONE:-$DEFAULT_ZONE}

read -rp "Enter your GitHub Repository in 'owner/repo' format (e.g. yourname/microbin): " GITHUB_REPO
if [ -z "$GITHUB_REPO" ]; then
  echo "Error: GitHub Repository is required for Workload Identity Federation."
  exit 1
fi

echo ""
echo "Starting provisioning for project: $PROJECT_ID..."
echo "Region: $REGION | Zone: $ZONE"
echo ""

# 1. Enable Required GCP APIs
echo "--> [1/5] Enabling required GCP APIs..."
gcloud services enable \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project="$PROJECT_ID"
echo "    APIs enabled."

# 2. Create Artifact Registry Docker Repository
echo "--> [2/5] Creating Artifact Registry repository ($GAR_REPO)..."
if ! gcloud artifacts repositories describe "$GAR_REPO" --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud artifacts repositories create "$GAR_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --description="MicroBin container repository" \
    --project="$PROJECT_ID"
  echo "    Artifact Registry created."
else
  echo "    Artifact Registry already exists."
fi

# 3. Create Service Account and Assign Roles
echo "--> [3/5] Creating Deployment Service Account ($SA_NAME)..."
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
if ! gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name="GitHub Actions MicroBin Deployer" \
    --project="$PROJECT_ID"
  echo "    Service Account created."
else
  echo "    Service Account already exists."
fi

echo "    Assigning IAM roles..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/artifactregistry.writer" --condition=None --quiet >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA_EMAIL" \
  --role="roles/compute.instanceAdmin.v1" --condition=None --quiet >/dev/null

# 4. Configure Workload Identity Federation (WIF / OIDC)
echo "--> [4/5] Configuring Workload Identity Federation (OIDC)..."
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')

# Create Workload Identity Pool
if ! gcloud iam workload-identity-pools describe "$POOL_NAME" --location="global" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "$POOL_NAME" \
    --project="$PROJECT_ID" \
    --location="global" \
    --display-name="GitHub Actions Pool"
  echo "    Workload Identity Pool created."
else
  echo "    Workload Identity Pool already exists."
fi

# Create OIDC Provider
if ! gcloud iam workload-identity-pools providers describe "$PROVIDER_NAME" \
  --workload-identity-pool="$POOL_NAME" \
  --location="global" \
  --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_NAME" \
    --project="$PROJECT_ID" \
    --location="global" \
    --workload-identity-pool="$POOL_NAME" \
    --display-name="GitHub Actions Provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository == '$GITHUB_REPO'"
  echo "    OIDC Provider created."
else
  echo "    OIDC Provider already exists."
fi

# Bind Service Account to GitHub Repo via WIF
echo "    Binding Service Account to repository: $GITHUB_REPO..."
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.repository/${GITHUB_REPO}" \
  --condition=None --quiet >/dev/null

WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/providers/${PROVIDER_NAME}"

# 5. Provision Always-Free e2-micro VM
echo "--> [5/5] Provisioning Always-Free e2-micro VM ($VM_NAME)..."
if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  
  # Startup script installs Docker and Docker Compose
  STARTUP_SCRIPT=$(cat << 'EOF'
#!/bin/bash
set -e
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release

# Install Docker Engine
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Setup application directories with isolated volumes
mkdir -p /opt/microbin/data/release
mkdir -p /opt/microbin/data/preview
chown -R 65532:65532 /opt/microbin/data
EOF
)

  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type="e2-micro" \
    --image-family="debian-12" \
    --image-project="debian-cloud" \
    --boot-disk-size="30GB" \
    --boot-disk-type="pd-standard" \
    --scopes="cloud-platform" \
    --metadata=startup-script="$STARTUP_SCRIPT"

  echo "    VM created successfully with 0 open public web ports!"
else
  echo "    VM $VM_NAME already exists."
fi

echo ""
echo "=========================================================================="
echo "                PROVISIONING COMPLETE (Zero Trust Security)               "
echo "=========================================================================="
echo ""
echo "Configure the following secrets in GitHub (Settings > Secrets > Actions):"
echo "--------------------------------------------------------------------------"
echo "GCP_PROJECT_ID:          $PROJECT_ID"
echo "WIF_PROVIDER:            $WIF_PROVIDER_RESOURCE"
echo "WIF_SERVICE_ACCOUNT:     $SA_EMAIL"
echo "DOMAIN_NAME:             yourdomain.com"
echo "CLOUDFLARE_TUNNEL_TOKEN: <YOUR_CLOUDFLARE_TUNNEL_TOKEN>"
echo "--------------------------------------------------------------------------"
echo ""
echo "Cloudflare Zero Trust Setup Steps:"
echo "1. Go to Cloudflare Zero Trust Dashboard > Networks > Tunnels > Create a Tunnel."
echo "2. Select 'Cloudflared', copy the Tunnel Token, and save it as CLOUDFLARE_TUNNEL_TOKEN in GitHub Secrets."
echo "3. Add two Public Hostnames under the Tunnel configuration:"
echo "   - Hostname: bin-release.yourdomain.com  --> Service: HTTP://microbin-release:8080"
echo "   - Hostname: bin-preview.yourdomain.com  --> Service: HTTP://microbin-preview:8080"
echo "=========================================================================="
