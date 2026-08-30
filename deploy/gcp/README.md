# GCP Always-Free Deployment Guide (Dual-Slot: Release & Preview)

This guide documents how MicroBin is deployed to **Google Cloud Platform (GCP)** under the **Always Free Tier** ($0.00/month) with automated **Let's Encrypt SSL/TLS certificates** and **keyless authentication** via GitHub Actions **OpenID Connect (OIDC) / Workload Identity Federation (WIF)**.

---

## 1. Dual-Slot Architecture

The Always-Free `e2-micro` VM concurrently hosts two isolated MicroBin environments behind Caddy:

| Environment | Subdomain | Branch Trigger | Storage Volume |
| :--- | :--- | :--- | :--- |
| **Release (Production)** | `bin-release.yourdomain.com` | `release/v*` | `microbin_release_data` |
| **Preview (Staging)** | `bin-preview.yourdomain.com` | `main` / PRs | `microbin_preview_data` |

```
                              Internet / Users
                                    │
                                    ▼
                     ┌──────────────────────────────┐
                     │     Caddy TLS Terminator     │
                     │  (Automatic Let's Encrypt)   │
                     └──────────────┬───────────────┘
                                    │
               ┌────────────────────┴────────────────────┐
               │ https://bin-release.domain.com          │ https://bin-preview.domain.com
               ▼                                         ▼
┌──────────────────────────────┐          ┌──────────────────────────────┐
│   MicroBin Release Slot      │          │   MicroBin Preview Slot      │
│   - Port: 8080               │          │   - Port: 8080               │
│   - Volume: release_data     │          │   - Volume: preview_data     │
│   - Target: release/v*       │          │   - Target: main / feature   │
└──────────────────────────────┘          └──────────────────────────────┘
```

---

## 2. DNS Configuration Checklist

After running the GCP setup script, configure **two `A` records** in your DNS provider (Cloudflare, Namecheap, Route53, etc.) pointing to the VM Public IP:

| Record Type | Host / Name | Target / Value | TTL |
| :--- | :--- | :--- | :--- |
| `A` | `bin-release` | `<VM_PUBLIC_IP>` | Auto / 300s |
| `A` | `bin-preview` | `<VM_PUBLIC_IP>` | Auto / 300s |

*(Alternatively, a wildcard record `*.yourdomain.com` pointing to the VM IP will cover both).*

---

## 3. GitHub Actions Secrets Configuration

Go to **Settings > Secrets and variables > Actions** in your GitHub repository and ensure the following 5 secrets are set:

| Secret Name | Description / Example |
| :--- | :--- |
| `GCP_PROJECT_ID` | Your Google Cloud Project ID |
| `WIF_PROVIDER` | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `WIF_SERVICE_ACCOUNT` | `microbin-deployer@<PROJECT_ID>.iam.gserviceaccount.com` |
| `DOMAIN_NAME` | Your root domain (e.g. `yourdomain.com`). Caddy will generate `bin-release.yourdomain.com` and `bin-preview.yourdomain.com`. |
| `ACME_EMAIL` | Your email address for Let's Encrypt renewal notifications |

---

## 4. Deployment Lifecycle

* **Preview Deployment:** Push to `main` (or trigger `deploy.yml` with `target_env: preview`). Deploys to `https://bin-preview.yourdomain.com`.
* **Release Deployment:** Push to `release/v*` (or trigger `deploy.yml` with `target_env: release`). Deploys to `https://bin-release.yourdomain.com`.
