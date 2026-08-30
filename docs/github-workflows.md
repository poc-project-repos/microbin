# GitHub Actions Workflows Guide

This document provides a comprehensive analysis of all GitHub Actions workflows configured in this repository, including their triggers, jobs, matrix strategies, security models, and deployment targets.

---

## 1. Workflows Overview

| Workflow | File | Trigger(s) | Primary Purpose |
| :--- | :--- | :--- | :--- |
| **CI: Build & Test** | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) | Push & PR to `master`, Manual | Fast verification of compilation and unit tests. |
| **Code Quality & Linting** | [`.github/workflows/code-quality.yml`](../.github/workflows/code-quality.yml) | Push/PR to `master`, Weekly Cron, Manual | Static code analysis, Clippy linting, and SARIF security reporting. |
| **Release Packages & Images** | [`.github/workflows/release.yml`](../.github/workflows/release.yml) | Manual (`workflow_dispatch`) | Multi-arch cross-compilation matrix, GitHub release assets, and optional multi-arch Docker Hub publishing. |
| **CD: Deploy to GCP Always-Free** | [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) | Push to `master`, Manual Dispatch | 100% keyless OIDC/WIF deployment to GCP `e2-micro` VM with Caddy Let's Encrypt TLS. |

---

## 2. Detailed Workflow Analysis

```
                        ┌──────────────────────────────┐
                        │       Git Event / Action     │
                        └──────────────┬───────────────┘
                                       │
         ┌─────────────────────────────┼────────────────────────────┬─────────────────────────────┐
         ▼                             ▼                            ▼                             ▼
┌──────────────────┐          ┌──────────────────┐         ┌──────────────────┐          ┌──────────────────┐
│   Push / PR to   │          │   Push / PR to   │         │ Manual Dispatch  │          │   Push to master │
│      master      │          │  master + Cron   │         │ (workflow_disp.) │          │ / Manual Dispatch│
└────────┬─────────┘          └────────┬─────────┘         └────────┬─────────┘          └────────┬─────────┘
         ▼                             ▼                            ▼                             ▼
┌──────────────────┐          ┌──────────────────┐         ┌──────────────────┐          ┌──────────────────┐
│      ci.yml      │          │ code-quality.yml │         │   release.yml    │          │    deploy.yml    │
│ - cargo build    │          │ - cargo clippy   │         │ 1. Build Matrix  │          │ - Keyless OIDC   │
│ - cargo test     │          │ - SARIF upload   │         │    (10 targets)  │          │ - Buildx GAR Push│
└──────────────────┘          └──────────────────┘         │ 2. GitHub Release│          │ - GCE SSH Deploy │
                                                           │ 3. Docker (opt.) │          │ - Caddy HTTPS    │
                                                           └──────────────────┘          └──────────────────┘
```

---

### Workflow 1: Continuous Integration (`ci.yml`)

* **File:** [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)
* **Execution Environment:** `ubuntu-latest`
* **Trigger:** Every push or pull request targeting the `master` branch, and manual `workflow_dispatch`.
* **Execution Steps:**
  1. `actions/checkout@v5`: Fetches repository source.
  2. `dtolnay/rust-toolchain@stable`: Sets up active Rust toolchain.
  3. `cargo build --verbose`: Compiles the binary in debug mode.
  4. `cargo test --verbose`: Runs all test suites (e.g. `animalnumbers.rs`).

---

### Workflow 2: Clippy Code Quality & Security Scan (`code-quality.yml`)

* **File:** [`.github/workflows/code-quality.yml`](../.github/workflows/code-quality.yml)
* **Execution Environment:** `ubuntu-latest`
* **Triggers:**
  * Push / PR targeting `master`.
  * Scheduled weekly cron: `35 12 * * 5` (every Friday at 12:35 UTC).
  * Manual `workflow_dispatch`.
* **Permissions:**
  * `security-events: write` (Required for uploading code scanning alerts to GitHub Security tab).
* **Execution Steps:**
  1. Installs the official Rust stable toolchain with the `clippy` component via `dtolnay/rust-toolchain`.
  2. Installs SARIF formatting utilities (`clippy-sarif`, `sarif-fmt`).
  3. Executes `cargo clippy --all-features --message-format=json` and formats output to `rust-clippy-results.sarif`.
  4. Uploads findings to GitHub Code Scanning via `github/codeql-action/upload-sarif@v3`.

---

### Workflow 3: Multi-Platform Release & Docker Hub Publication (`release.yml`)

* **File:** [`.github/workflows/release.yml`](../.github/workflows/release.yml)
* **Trigger:** Manual trigger via GitHub Actions UI (**Run workflow** under `workflow_dispatch`).
* **Inputs:**
  * `tag_name`: The semantic version release tag (e.g. `v2.1.4`).
  * `is_prerelease`: Checkbox option to mark as a GitHub Pre-release.
  * `publish_docker`: Optional checkbox (default: `false`) to build and push multi-arch images to Docker Hub.

#### Job 1: `release` (Cross-Compilation Matrix)
Uses a **10-platform matrix** to build static binaries for all major OS and CPU architectures:

| Target Platform Triple | Runner OS | Build Tool | Output Package |
| :--- | :--- | :--- | :--- |
| `x86_64-unknown-linux-musl` | `ubuntu-latest` | `cross` | `.tar.gz` |
| `aarch64-unknown-linux-musl` | `ubuntu-latest` | `cross` | `.tar.gz` |
| `i686-unknown-linux-musl` | `ubuntu-latest` | `cross` | `.tar.gz` |
| `armv7-unknown-linux-musleabihf` | `ubuntu-latest` | `cross` | `.tar.gz` |
| `arm-unknown-linux-musleabihf` | `ubuntu-latest` | `cross` | `.tar.gz` |
| `x86_64-apple-darwin` | `macos-latest` | native `cargo` | `.tar.gz` |
| `aarch64-apple-darwin` | `macos-latest` | `cross` | `.tar.gz` |
| `x86_64-pc-windows-msvc` | `windows-latest` | native `cargo` | `.zip` |
| `i686-pc-windows-msvc` | `windows-latest` | `cross` | `.zip` |
| `aarch64-pc-windows-msvc` | `windows-latest` | `cross` (`no-c-deps`) | `.zip` |

* **Packaging & Publishing:** Automatically packages binaries into `.tar.gz` or `.zip` archives and publishes them to **GitHub Releases** via `softprops/action-gh-release@v2`.

#### Job 2: `docker` (Optional Docker Hub Multi-Arch Images)
* **Execution Condition:** Runs only when `publish_docker: true` is selected in the manual trigger.
* **Dependencies:** Depends on the successful completion of the `release` job (`needs: release`).
* **Multi-Arch Support:** Uses QEMU (`docker/setup-qemu-action@v3`) and Docker Buildx (`docker/setup-buildx-action@v3`) to cross-build multi-architecture container images for:
  * `linux/amd64`
  * `linux/arm64`
* **Automated Tagging:** Generates semantic version tags (`v2.1.4` and `latest`) via `docker/metadata-action@v5` and pushes to Docker Hub.

---

### Workflow 4: Continuous Deployment to GCP Always-Free (`deploy.yml`)

* **File:** [`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)
* **Triggers:**
  * Automatic push to `master`.
  * Manual `workflow_dispatch` with interactive inputs for region (`us-central1`, `us-east1`, `us-west1`) and zone (`us-central1-a`, etc.).
* **Security & Auth:** **100% Keyless OIDC / Workload Identity Federation (WIF)**:
  * Requests GitHub OIDC token with `id-token: write`.
  * Exchanges token with GCP Security Token Service for a short-lived OAuth2 access token.
* **Execution Steps:**
  1. Authenticates against Google Cloud via `google-github-actions/auth@v2` with `WIF_PROVIDER` and `WIF_SERVICE_ACCOUNT`.
  2. Configures Docker credentials for Google Artifact Registry (`<region>-docker.pkg.dev`).
  3. Builds and pushes the distroless container image tagged with the commit SHA and `latest`.
  4. Connects to the Always-Free `e2-micro` VM via `gcloud compute ssh`.
  5. Transfers [`Caddyfile`](../deploy/gcp/Caddyfile) and [`docker-compose.prod.yml`](../deploy/gcp/docker-compose.prod.yml) to `/opt/microbin/`.
  6. Executes `docker compose pull && docker compose up -d`, achieving zero-downtime rolling container updates while preserving Let's Encrypt certificates and SQLite database mounts.

---

## 3. Required GitHub Secrets & Permissions Reference

### Repository Secrets

| Secret Name | Consuming Workflow(s) | Description |
| :--- | :--- | :--- |
| `GCP_PROJECT_ID` | `deploy.yml` | Google Cloud Project ID |
| `WIF_PROVIDER` | `deploy.yml` | Full resource path of the GCP Workload Identity Provider |
| `WIF_SERVICE_ACCOUNT` | `deploy.yml` | GCP Service Account email (`microbin-deployer@...`) |
| `DOMAIN_NAME` | `deploy.yml` | FQDN for Let's Encrypt TLS (e.g. `bin.yourdomain.com`) |
| `ACME_EMAIL` | `deploy.yml` | Email address for Let's Encrypt renewal notifications |
| `DOCKERHUB_USERNAME` | `release.yml` | Docker Hub username |
| `DOCKERHUB_TOKEN` | `release.yml` | Docker Hub access token |
| `DOCKERHUB_REPO` | `release.yml` | Target Docker Hub repository path (e.g. `user/microbin`) |

---

## 4. Manual Execution with GitHub CLI (`gh`)

```bash
# Run CI Build & Test
gh workflow run ci.yml

# Run Code Quality & Clippy Scan
gh workflow run code-quality.yml

# Run CD Deploy to GCP Always-Free
gh workflow run deploy.yml

# Run Release
gh workflow run release.yml -f tag_name=v2.1.4 -f publish_docker=false
```
