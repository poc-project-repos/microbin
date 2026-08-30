# GCP Always-Free Deployment Guide (Cloudflare Zero Trust Tunnel + Dual-Slot)

This guide documents how MicroBin is deployed to **Google Cloud Platform (GCP)** under the **Always Free Tier** ($0.00/month) with **Cloudflare Zero Trust Tunnel**, **Edge TLS Termination**, and **keyless GitHub OIDC authentication**.

---

## 1. Architectural Overview & Threat Model

Instead of exposing public web ports (80/443) or managing dynamic public IPs and ACME certificate challenges on the VM, this architecture uses a **Cloudflare Zero Trust Tunnel (`cloudflared`)**:

```
                              Internet / End Users
                                       │
                                       ▼
                   ┌───────────────────────────────────────┐
                   │        Cloudflare Edge Network        │
                   │  - Universal SSL/TLS Termination      │
                   │  - DDoS Layer 3/4/7 Protection        │
                   │  - WAF & Rate Limiting                │
                   └───────────────────┬───────────────────┘
                                       │
                    Encrypted Outbound Tunnel (QUIC / TLS)
                       (0 Inbound Ports Open on GCP!)
                                       │
                                       ▼
┌─ GCP Always-Free e2-micro VM ──────────────────────────────────────────────┐
│                                                                            │
│   ┌────────────────────────────────────────────────────────────────────┐   │
│   │ cloudflared (Tunnel Daemon)                                        │   │
│   └────────────────┬──────────────────────────────────┬────────────────┘   │
│                    │                                  │                    │
│   http://microbin-release:8080       http://microbin-preview:8080          │
│                    ▼                                  ▼                    │
│   ┌────────────────────────────────┐ ┌─────────────────────────────────┐   │
│   │ microbin-release (Release Slot)│ │ microbin-preview (Preview Slot) │   │
│   │ - Domain: bin-release.domain   │ │ - Domain: bin-preview.domain    │   │
│   │ - Trigger: release/v* branches │ │ - Trigger: main / PR branches   │   │
│   │ - Data: /data/release          │ │ - Data: /data/preview           │   │
│   └────────────────────────────────┘ └─────────────────────────────────┘   │
│                                                                            │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Key Architectural Advantages

1. **Zero Open Inbound Ports on GCP:**
   The GCP VM has no firewall rules open for HTTP or HTTPS. Port 80 and port 443 do not exist on the public internet.
2. **100% Immunity to Dynamic IP Changes:**
   `cloudflared` initiates outbound connections to Cloudflare Edge servers. The VM's public IP address can change at any time without impacting traffic or requiring DNS updates.
3. **No Let's Encrypt Rate Limits:**
   All public HTTPS certificates are managed at Cloudflare's Edge, eliminating ACME HTTP-01 challenges and the 50 certs/week domain limits.
4. **Complete Dual-Slot Isolation:**
   Production (`bin-release`) and Staging/Preview (`bin-preview`) run as isolated container services with separate SQLite storage volumes.

---

## 3. Prerequisites Checklist

| Prerequisite | Purpose |
| :--- | :--- |
| **1. Cloudflare Account** | To manage your domain DNS and create the Cloudflare Zero Trust Tunnel. |
| **2. GCP Account** | Always-Free eligible project with billing enabled ($0.00 spend). |
| **3. Google Cloud CLI (`gcloud`)** | Authenticated on your local machine to run the provisioning script. |
| **4. GitHub Repository Admin** | To configure GitHub Actions repository secrets. |

---

## 4. Step-by-Step Setup Guide

### Step 1: Create Cloudflare Zero Trust Tunnel
1. Log into the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/).
2. Navigate to **Networks > Tunnels > Add a tunnel**.
3. Choose **Cloudflared** and give the tunnel a name (e.g. `microbin-gcp-tunnel`).
4. Click **Save tunnel**. Under the install command, copy the **Tunnel Token** (the long base64 string after `--token`).
5. In the **Public Hostnames** tab of your tunnel, add two routes:

| Public Hostname | Service Type | Service URL |
| :--- | :--- | :--- |
| `bin-release.yourdomain.com` | `HTTP` | `microbin-release:8080` |
| `bin-preview.yourdomain.com` | `HTTP` | `microbin-preview:8080` |

6. Save the tunnel.

---

### Step 2: Provision GCP Infrastructure

Run the automated setup script from your local machine:

```bash
gcloud auth login
chmod +x deploy/gcp/setup-always-free-vm.sh
./deploy/gcp/setup-always-free-vm.sh
```

---

### Step 3: Configure GitHub Secrets

Go to your repository: **Settings > Secrets and variables > Actions > New repository secret** and add:

| Secret Name | Value Description |
| :--- | :--- |
| `GCP_PROJECT_ID` | Your GCP Project ID |
| `WIF_PROVIDER` | `projects/<NUM>/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `WIF_SERVICE_ACCOUNT` | `microbin-deployer@<PROJECT_ID>.iam.gserviceaccount.com` |
| `DOMAIN_NAME` | Your base domain (e.g. `yourdomain.com`) |
| `CLOUDFLARE_TUNNEL_TOKEN` | The Cloudflare Tunnel Token copied in Step 1 |

---

## 5. Deployment Lifecycle

* **Preview Deployment:** Push to `main` (or trigger `deploy.yml` manually). Deploys to `https://bin-preview.yourdomain.com`.
* **Release Deployment:** Push to `release/v*` (or trigger `deploy.yml` with `target_env: release`). Deploys to `https://bin-release.yourdomain.com`.

---

## 6. Diagnostic Commands (SSH to VM)

```bash
# SSH into VM
gcloud compute ssh microbin-free-tier --zone=us-east1-b

# Check container status
sudo docker compose -f /opt/microbin/docker-compose.prod.yml ps

# View Cloudflare Tunnel connection logs
sudo docker compose -f /opt/microbin/docker-compose.prod.yml logs cloudflared

# View MicroBin logs
sudo docker compose -f /opt/microbin/docker-compose.prod.yml logs microbin-release
sudo docker compose -f /opt/microbin/docker-compose.prod.yml logs microbin-preview
```
