# GCP Always-Free Deployment Guide (Keyless OIDC + Let's Encrypt)

This guide documents everything required to host MicroBin on **Google Cloud Platform (GCP)** under the **Always Free Tier** ($0.00/month) with automated **Let's Encrypt SSL/TLS certificates** and **keyless authentication** via GitHub Actions **OpenID Connect (OIDC) / Workload Identity Federation (WIF)**.

---

## 1. Prerequisites Checklist

Before running the setup, ensure you have the following ready:

| Prerequisite | Why It Is Needed |
| :--- | :--- |
| **1. GCP Account with Active Billing** | Required by Google Cloud to provision Compute Engine resources and Artifact Registry. *(You will not be billed as long as you stay within the Always Free limits).* |
| **2. Google Cloud CLI (`gcloud`)** | Installed and authenticated on your local machine (`gcloud auth login`) to run the one-time provisioning script. |
| **3. Registered Domain Name** | A domain or subdomain (e.g. `bin.yourdomain.com`) where you have access to configure DNS `A` records for Let's Encrypt certificate issuance. |
| **4. GitHub Repository Admin Rights** | Required to configure repository secrets (**Settings > Secrets and variables > Actions**). |

---

## 2. Architecture & Trust Model

### How GitHub Actions Authenticates with GCP (OIDC / WIF)

Instead of storing vulnerable, long-lived JSON service account keys in GitHub Secrets, this project uses **Workload Identity Federation (OAuth 2.0 / OIDC)**:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. GitHub Actions Workflow (.github/workflows/deploy.yml)│
│    - Job requests signed OIDC JSON Web Token (JWT)          │
│    - Audience: 'https://iam.googleapis.com/...'             │
│    - Claims: { "repository": "owner/microbin", ... }        │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. GCP Security Token Service (STS)                         │
│    - Validates signature against GitHub OIDC Issuer         │
│      (https://token.actions.githubusercontent.com)          │
│    - Matches Workload Identity Pool: 'github-pool'          │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. GCP IAM Policy Binding Check                             │
│    - Verifies 'roles/iam.workloadIdentityUser' is bound to: │
│      principalSet://.../attribute.repository/owner/microbin │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 4. Service Account Impersonation ('microbin-deployer')      │
│    - Issues a temporary 1-hour OAuth2 Bearer Token          │
│    - Grants 'roles/artifactregistry.writer'                 │
│    - Grants 'roles/compute.instanceAdmin.v1'                │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 5. GCE e2-micro VM (Always-Free Tier)                       │
│    - Docker pull latest image from Artifact Registry        │
│    - Caddy reverse proxy terminates HTTPS with Let's Encrypt│
│    - Persistent storage at /app/microbin_data preserved    │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. GCP Always-Free Tier Eligibility Rules

Google Cloud provides **one free `e2-micro` VM per month** under these strict conditions:

* **Eligible US Regions Only:**
  * `us-central1` (Iowa) — *Recommended default*
  * `us-east1` (South Carolina)
  * `us-west1` (Oregon)
* **Instance Type:** `e2-micro` (2 vCPUs burstable, 1 GB RAM).
* **Boot Disk:** Up to 30 GB standard persistent disk (`pd-standard`). *Do NOT select SSD (`pd-ssd`) or Balanced (`pd-balanced`).*
* **Network Egress:** 1 GB free outbound data transfer per month to Americas/EMEA.

---

## 4. One-Time Setup (Automated Bootstrap)

Run the provided helper script from your local terminal:

```bash
# 1. Login to gcloud and set your project
gcloud auth login
gcloud config set project <YOUR_GCP_PROJECT_ID>

# 2. Run bootstrap script
chmod +x deploy/gcp/setup-always-free-vm.sh
./deploy/gcp/setup-always-free-vm.sh
```

### What the Script Provisions:
1. **APIs:** Enables `compute.googleapis.com`, `artifactregistry.googleapis.com`, `iam.googleapis.com`, `iamcredentials.googleapis.com`, and `sts.googleapis.com`.
2. **Artifact Registry:** Creates Docker repository `microbin-repo` in `us-central1`.
3. **Firewall:** Opens TCP ports `80` (HTTP), `443` (HTTPS), and UDP port `443` (HTTP/3 QUIC) tagged with `microbin-web`.
4. **Service Account:** Creates `microbin-deployer@<PROJECT_ID>.iam.gserviceaccount.com` with:
   * `roles/artifactregistry.writer` (to push Docker images)
   * `roles/compute.instanceAdmin.v1` (to deploy & manage containers on the VM)
5. **Workload Identity Federation:**
   * Pool: `github-pool`
   * Provider: `github-provider` (mapped to GitHub's OIDC issuer)
   * Principal binding: Locked specifically to your repository (`attribute.repository/<GITHUB_REPO>`).
6. **VM Instance:** Launches the `e2-micro` VM (`microbin-free-tier`) running Debian 12 with Docker & Docker Compose.

---

## 5. DNS Configuration

After running the script, note the **VM Public IP** printed in the output. In your DNS provider (Cloudflare, Namecheap, Route53, etc.), create an **`A` record**:

| Type | Name / Host | Value / Target | TTL |
| :--- | :--- | :--- | :--- |
| `A` | `bin` (or `@`) | `<VM_PUBLIC_IP>` | Auto / 300s |

> [!NOTE]
> Ensure the DNS record is propagated before triggering the first deployment so Caddy can complete the Let's Encrypt ACME HTTP-01 challenge.

---

## 6. GitHub Actions Secrets Configuration

Go to your repository on GitHub: **Settings > Secrets and variables > Actions > New repository secret** and add these 5 secrets:

| Secret Name | Description / Example Value |
| :--- | :--- |
| `GCP_PROJECT_ID` | Your GCP Project ID (e.g. `my-microbin-project-12345`). |
| `WIF_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `WIF_SERVICE_ACCOUNT` | `microbin-deployer@<YOUR_PROJECT_ID>.iam.gserviceaccount.com` |
| `DOMAIN_NAME` | Your fully qualified domain (e.g. `bin.yourdomain.com`). |
| `ACME_EMAIL` | Your email address (used by Let's Encrypt for renewal alerts). |

---

## 7. Verifying Deployment & Troubleshooting

### Trigger Deployment
Push a commit to `master` or manually trigger the workflow from the **Actions** tab by selecting **Deploy to GCP Always-Free (OIDC / WIF) > Run workflow**.

### Verify Ingress & TLS
Once deployment finishes:
1. Navigate to `https://bin.yourdomain.com` in your browser.
2. Confirm the SSL/TLS padlock icon shows a valid certificate issued by Let's Encrypt.
3. Test creating a paste to verify SQLite database writes and file attachments.

### Diagnostic Commands (SSH to VM)
```bash
# SSH into the running instance
gcloud compute ssh microbin-free-tier --zone=us-central1-a

# Check container status
sudo docker compose -f /opt/microbin/docker-compose.prod.yml ps

# View Caddy TLS & access logs
sudo docker compose -f /opt/microbin/docker-compose.prod.yml logs caddy

# View MicroBin application logs
sudo docker compose -f /opt/microbin/docker-compose.prod.yml logs microbin
```
