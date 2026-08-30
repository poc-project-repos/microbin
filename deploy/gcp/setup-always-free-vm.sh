#!/usr/bin/env bash
# ==============================================================================
# Setup script for GCP Always-Free Tier e2-micro instance for MicroBin with
# Caddy TLS Terminator and Keyless OIDC / Workload Identity Federation (WIF)
# Eligible Always-Free regions: us-central1, us-east1, us-west1
# ==============================================================================

set -euo pipefail

# Configuration Defaults
PROJECT_ID="${GCP_PROJECT_ID:-$(gcloud config get-value project 2>/dev/null || true)}"
REGION="${GCP_REGION:-us-central1}"
ZONE="${GCP_ZONE:-us-central1-a}"
GAR_REPO="microbin-repo"
VM_NAME="microbin-free-tier"
SA_NAME="microbin-deployer"
POOL_NAME="github-pool"
PROVIDER_NAME="github-provider"
GITHUB_REPO="${GITHUB_REPO:-}"
DOMAIN_NAME="${DOMAIN_NAME:-}"
ACME_EMAIL="${ACME_EMAIL:-}"

if [ -z "$PROJECT_ID" ]; then
  echo "Error: PROJECT_ID is not set. Run 'gcloud config set project <your-project-id>' or set GCP_PROJECT_ID."
  exit 1
fi

echo "=========================================================="
echo "Initializing MicroBin GCP Always-Free Infrastructure"
echo "Project ID : $PROJECT_ID"
echo "Region     : $REGION (Always-Free eligible)"
echo "Zone       : $ZONE"
echo "=========================================================="

# Prompt for GitHub Repository, Domain, and Email if not provided
if [ -z "$GITHUB_REPO" ]; then
  read -rp "Enter your GitHub repository (e.g. poc-project-repos/microbin): " GITHUB_REPO
fi

if [ -z "$DOMAIN_NAME" ]; then
  read -rp "Enter your domain name for Let's Encrypt (e.g. bin.example.com): " DOMAIN_NAME
fi

if [ -z "$ACME_EMAIL" ]; then
  read -rp "Enter your email for Let's Encrypt certificate expiry notices: " ACME_EMAIL
fi

# 1. Enable Required GCP APIs
echo "--> [1/6] Enabling required Google Cloud APIs..."
gcloud services enable \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  --project="$PROJECT_ID"

# 2. Create Artifact Registry Repository
echo "--> [2/6] Setting up Google Artifact Registry repository ($GAR_REPO)..."
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

# 3. Create Firewall Rules for HTTP and HTTPS
echo "--> [3/6] Creating Firewall rules for HTTP & HTTPS (Let's Encrypt)..."
if ! gcloud compute firewall-rules describe allow-microbin-web --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud compute firewall-rules create allow-microbin-web \
    --project="$PROJECT_ID" \
    --direction=INGRESS \
    --priority=1000 \
    --network=default \
    --action=ALLOW \
    --rules=tcp:80,tcp:443,udp:443 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=microbin-web \
    --description="Allow HTTP, HTTPS, and HTTP/3 QUIC traffic to Caddy and MicroBin"
  echo "    Firewall rule created."
else
  echo "    Firewall rule already exists."
fi

# 4. Create Service Account and Assign Roles
echo "--> [4/6] Creating Deployment Service Account ($SA_NAME)..."
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

# 5. Configure Workload Identity Federation (WIF / OIDC)
echo "--> [5/6] Configuring Workload Identity Federation (OIDC)..."
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
if ! gcloud iam workload-identity-pools providers describe "$PROVIDER_NAME" --workload-identity-pool="$POOL_NAME" --location="global" --project="$PROJECT_ID" >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER_NAME" \
    --project="$PROJECT_ID" \
    --location="global" \
    --workload-identity-pool="$POOL_NAME" \
    --display-name="GitHub Actions OIDC Provider" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository"
  echo "    OIDC Provider created."
else
  echo "    OIDC Provider already exists."
fi

# Allow GitHub Repository to impersonate the Service Account
gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
  --project="$PROJECT_ID" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/attribute.repository/${GITHUB_REPO}" \
  --condition=None --quiet >/dev/null

WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL_NAME}/providers/${PROVIDER_NAME}"

# 6. Provision Always-Free e2-micro VM Instance with Docker + Caddy
echo "--> [6/6] Provisioning or configuring e2-micro VM ($VM_NAME)..."

STARTUP_SCRIPT=$(cat << 'EOF'
#!/bin/bash
set -euo pipefail

# Install Docker & Docker Compose Plugin
if ! command -v docker &> /dev/null; then
  apt-get update
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi

mkdir -p /opt/microbin
EOF
)

if ! gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "    Creating new e2-micro Always-Free VM..."
  gcloud compute instances create "$VM_NAME" \
    --project="$PROJECT_ID" \
    --zone="$ZONE" \
    --machine-type=e2-micro \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --boot-disk-size=30GB \
    --boot-disk-type=pd-standard \
    --tags=microbin-web,http-server,https-server \
    --metadata=startup-script="$STARTUP_SCRIPT"
  echo "    VM created."
else
  echo "    VM already exists."
fi

# Get Public Static/External IP of the VM
VM_IP=$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

echo ""
echo "=========================================================="
echo " Setup Completed Successfully (Keyless OIDC Configured)!"
echo "=========================================================="
echo ""
echo "VM Public IP : $VM_IP"
echo ""
echo "NEXT STEPS:"
echo "1. Configure DNS: Create an 'A' record in your DNS registrar:"
echo "   $DOMAIN_NAME  ->  $VM_IP"
echo ""
echo "2. Configure GitHub Secrets (Settings > Secrets and variables > Actions):"
echo "   - GCP_PROJECT_ID       : $PROJECT_ID"
echo "   - WIF_PROVIDER         : $WIF_PROVIDER_RESOURCE"
echo "   - WIF_SERVICE_ACCOUNT  : $SA_EMAIL"
echo "   - DOMAIN_NAME          : $DOMAIN_NAME"
echo "   - ACME_EMAIL           : $ACME_EMAIL"
echo ""
echo "Note: No JSON key files were generated. Authentication is 100% keyless via OIDC!"
echo ""
