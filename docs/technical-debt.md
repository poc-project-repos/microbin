# Technical Debt & Architecture Modernization Backlog

This document tracks identified architectural bottlenecks, legacy dependencies, compiler warnings, and security improvements to be addressed in upcoming refactoring cycles.

---

## 1. Dependency Modernization & Compiler Warnings

### TD-01: Askama Template Engine Upgrade & `nom 6.1.2` Incompatibility
* **Category:** Dependencies / Build Warnings
* **Impacted Files:** [`Cargo.toml`](../Cargo.toml), [`src/endpoints/*.rs`](../src/endpoints/)
* **Description:** 
  The current Askama dependency (`askama = "0.10"` via `askama-filters = "0.1.3"`) pulls in `nom v6.1.2`. The Rust compiler flags `nom v6.1.2` with future incompatibility warnings for upcoming compiler editions (`warning: nom v6.1.2 contain code that will be rejected by a future version of Rust`).
* **Proposed Action:**
  * Upgrade `askama` to modern `0.12+` / `0.13+` (which uses `nom 7+` and `syn 2`).
  * Migrate date/time template filters to Askama's built-in filtering syntax.
  * Verify all HTML templates compile cleanly with `cargo check`.

---

### TD-02: Deprecated Cryptography (`magic-crypt`)
* **Category:** Security / Cryptography
* **Impacted Files:** [`Cargo.toml`](../Cargo.toml), [`src/util/crypto.rs`](../src/util/)
* **Description:**
  MicroBin uses `magic-crypt = "3.1.13"`, an unmaintained wrapper crate that uses older encryption modes (CBC without AEAD authentication).
* **Proposed Action:**
  * Migrate to standard RustCrypto AEAD implementations (`aes-gcm = "0.10"` or `chacha20poly1305 = "0.10"`).
  * Ensure backward-compatible decryption routines for existing encrypted pastes.

---

### TD-03: CLI Parser Upgrade (`clap 3` $\rightarrow$ `clap 4`)
* **Category:** Dependencies / Maintenance
* **Impacted Files:** [`Cargo.toml`](../Cargo.toml), [`src/args.rs`](../src/args.rs)
* **Description:**
  MicroBin uses `clap 3.1.12`. Clap 4 offers better compile-time performance, smaller binary sizes, and cleaner derive macros.
* **Proposed Action:**
  * Upgrade `clap` to `4.x` with `features = ["derive", "env"]`.

---

## 2. Core Architecture & Concurrency

### TD-04: Global State Lock Contention (`Mutex<Vec<Pasta>>`)
* **Category:** Performance / Concurrency
* **Impacted Files:** [`src/main.rs`](../src/main.rs), [`src/pasta.rs`](../src/pasta.rs)
* **Description:**
  `AppState` maintains an in-memory index wrapped in a global blocking `Mutex<Vec<Pasta>>`. Under high concurrent read/write traffic, every request blocks on this single mutex lock.
* **Proposed Action:**
  * Replace the global `Mutex<Vec<Pasta>>` with a lock-free concurrent map (`dashmap` / `parking_lot::RwLock`) or rely directly on SQLite connection pooling with an in-memory cache.

---

### TD-05: Panic Risks & `.unwrap()` Elimination
* **Category:** Reliability / Error Handling
* **Impacted Files:** [`src/endpoints/*.rs`](../src/endpoints/)
* **Description:**
  There are over 70 instances of `.unwrap()` and `.expect()` across HTTP request handler paths. An unexpected payload, corrupt file, or lock error could trigger a thread panic and degrade service availability.
* **Proposed Action:**
  * Introduce custom error types (`thiserror` / Actix `ResponseError`).
  * Replace `.unwrap()` with `?` error propagation and return structured HTTP error responses (e.g. 400 Bad Request, 500 Internal Error).

---

## 3. Observability & Code Quality

### TD-06: Structured Logging & Tracing
* **Category:** Observability / Operations
* **Impacted Files:** [`Cargo.toml`](../Cargo.toml), [`src/main.rs`](../src/main.rs)
* **Description:**
  Currently uses basic `log` / `env_logger` emitting unstructured plain text without request correlation IDs or JSON output support for cloud monitoring (GCP Cloud Logging / Datadog).
* **Proposed Action:**
  * Adopt `tracing` and `tracing-actix-web`.
  * Support optional structured JSON log formatting via environment variable (`MICROBIN_LOG_FORMAT=json`).

---

### TD-07: Endpoint Logic Duplication
* **Category:** Code Maintainability
* **Impacted Files:** [`src/endpoints/auth_upload.rs`](../src/endpoints/auth_upload.rs), [`src/endpoints/create.rs`](../src/endpoints/create.rs), [`src/endpoints/pasta.rs`](../src/endpoints/pasta.rs)
* **Description:**
  Paste ID generation, pasta expiration checks, and authentication logic are duplicated across multiple endpoint handlers.
* **Proposed Action:**
  * Extract shared helper functions into dedicated service modules under `src/services/`.
