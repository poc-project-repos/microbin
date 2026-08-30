# Branching Strategy & Automated Versioning Standard

This document defines the official Git branching strategy, commit conventions, pull request workflow, and automated versioning lifecycle for the MicroBin project.

---

## 1. Branching Model: Main Trunk + Versioned Release Branches (`release/vX.Y.Z`)

We employ a **Trunk-Based Git Flow** centered around the `main` development branch and dedicated semantic release branches (`release/vX.Y.Z`):

```
                      ┌────── feature/user-auth ──────┐
                      │                               │ (PR + CI Checks)
───●──────────────────●───────────────────────────────●──────────────────● (main: active development)
   │                                                  │
   │                                                  ▼ (Cut Release Branch)
───●──────────────────────────────────────────────────●──────────────────● (release/v2.2.0: production)
                                                      │
                                                      ├─► [CD: Deploy to GCP Always-Free]
                                                      └─► [Release Packages & Images]
```

### Branch Roles & Lifecycle

| Branch | Pattern | Purpose | CI/CD Rules |
| :--- | :--- | :--- | :--- |
| **Active Development** | `main` | Primary active development trunk. All feature PRs, bug fixes, and refactoring merge here. | Runs full CI checks on PRs and merges. Direct push disabled. |
| **Release Branches** | **`release/vX.Y.Z`**<br>*(e.g. `release/v2.2.0`)* | Dedicated production release branches. Created when preparing or stabilizing a release. | Automatically triggers CD deployment to GCP Always-Free and enables release artifact builds. |
| **Feature Branches** | **`feature/*`**<br>*(e.g. `feature/clipboard-paste`)* | New capabilities, user-facing enhancements, and architecture expansions. | Triggers full CI build and unit testing. |
| **Fix Branches** | **`fix/*`**<br>*(e.g. `fix/sqlite-deadlock`)* | Bug fixes, regression resolutions, and security patches. | Triggers full CI build and unit testing. |
| **Refactor Branches** | **`refactor/*`** | Internal code restructuring with no external behavior changes. | Evaluated with CI when targeting PRs. |
| **Maintenance & Docs** | **`chore/*`**, **`docs/*`** | Tooling adjustments, documentation additions, license/readme updates. | **Skips CI build/test pipelines** to save runner minutes. |

---

## 2. CI/CD Conditional Execution (Intelligent Skipping)

To optimize developer feedback loops and eliminate redundant runner minutes, [`ci.yml`](../.github/workflows/ci.yml) and [`code-quality.yml`](../.github/workflows/code-quality.yml) automatically **skip compilation and testing** when a commit does not modify functional application code.

### When CI Build & Test Executes:
* **Release Branches:** Any push or PR on `release/v*`.
* **Feature & Fix Branches:** Any branch prefixed with `feature/*` or `fix/*`.
* **Conventional Commit Types:** Any commit or PR titled with `feat:`, `fix:`, or `release:`.
* **Manual Dispatch:** Explicit manual runs triggered via GitHub Actions UI / CLI.

### When CI Build & Test Is Skipped:
* Commits modifying only documentation (`docs/**`, `*.md`), license files, `.gitignore`, or `.agents/**`.
* Commits tagged with `chore:`, `docs:`, `style:`, or `ci:` that do not alter application source code.

---

## 3. Commit Message Standards: Conventional Commits

Commit messages drive automated changelog generation and automated semantic version bumping.

### Format:
```
<type>(<optional scope>): <short summary in imperative mood>

[optional body explaining motivation and architectural context]

[optional footer referencing issue numbers: Fixes #123]
```

### Allowed Types:
* `feat`: A new feature (**triggers MINOR version bump**, e.g., `2.1.4` $\rightarrow$ `2.2.0`)
* `fix`: A bug fix (**triggers PATCH version bump**, e.g., `2.1.4` $\rightarrow$ `2.1.5`)
* `feat!`/`fix!`: Breaking changes (**triggers MAJOR version bump**, e.g., `2.1.4` $\rightarrow$ `3.0.0`)
* `perf`: Performance improvements
* `refactor`: Code cleanup without feature/bug alterations
* `chore`: Tooling, build scripts, dependency updates
* `docs`: Documentation-only updates

---

## 4. Automated Version Numbering in `Cargo.toml`

Manual editing of `version = "..."` inside [`Cargo.toml`](../Cargo.toml) is prohibited to eliminate human error and version drift.

### Single Source of Truth Automation Flow:

```
┌─────────────────────────────────────────────────────────────┐
│ 1. Cut Release Branch: 'release/v2.2.0'                      │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 2. Automated Cargo.toml & Cargo.lock Sync                   │
│    - Strips 'v' prefix -> '2.2.0'                           │
│    - Updates Cargo.toml version field automatically         │
│    - Compiles matrix binaries & Docker images with SSOT tag │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ 3. Automated Git Tag & Release Artifacts                    │
│    - Tags commit as 'v2.2.0'                                │
│    - Publishes GitHub Release assets automatically          │
│    - Rolls out container to GCP Always-Free VM              │
└─────────────────────────────────────────────────────────────┘
```

### Tooling & Automation:
1. **CI/CD Release Automation:** In [`.github/workflows/release.yml`](../.github/workflows/release.yml), when a release tag is targeted, `Cargo.toml` is automatically synchronized across all cross-compilation runner environments.
2. **Local CLI Automation:** Use the [`scripts/bump-version.sh`](../scripts/bump-version.sh) script to bump versions locally:
   ```bash
   ./scripts/bump-version.sh 2.2.0
   ```

---

## 5. End-to-End Release Workflow

1. Developers work in `feature/xyz` or `fix/xyz` branches off `main`.
2. PR is opened targeting `main`, verified by `CI: Build & Test` and `Code Quality & Linting`.
3. When cutting a release, create branch `release/vX.Y.Z` (e.g. `release/v2.2.0`):
   ```bash
   git checkout -b release/v2.2.0 main
   ./scripts/bump-version.sh 2.2.0
   git commit -am "chore(release): bump version to v2.2.0"
   git push -u origin release/v2.2.0
   ```
4. Pushing `release/v2.2.0` automatically triggers the GCP Always-Free deployment pipeline and allows generating release assets.
