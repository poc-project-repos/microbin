# ==============================================================================
# Single Source of Truth (SSOT) for Base Image Tags (12-Factor II & X)
# ==============================================================================
ARG RUST_IMAGE_TAG=1-bookworm
ARG DISTROLESS_IMAGE=gcr.io/distroless/cc-debian12:latest

# --- Build Stage ---
FROM rust:${RUST_IMAGE_TAG} AS build

WORKDIR /app

RUN DEBIAN_FRONTEND=noninteractive \
    apt-get update && \
    apt-get -y install --no-install-recommends ca-certificates tzdata liblzma-dev libbz2-dev && \
    rm -rf /var/lib/apt/lists/*

COPY . .

RUN CARGO_NET_GIT_FETCH_WITH_CLI=true cargo build --release && \
    mkdir -p /app/microbin_data

# --- Runtime Stage ---
# Distroless cc-debian12 includes nonroot user (uid:gid 65532:65532) and minimal glibc/libgcc
FROM ${DISTROLESS_IMAGE}

WORKDIR /app

# copy time zone info from build stage
COPY --from=build /usr/share/zoneinfo /usr/share/zoneinfo

# copy CA certificates from build stage
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

# copy runtime dynamic libraries required by compression crates (bzip2, lzma)
COPY --from=build /lib/*-linux-gnu/liblzma.so.5* /lib/
COPY --from=build /usr/lib/*-linux-gnu/liblzma.so.5* /usr/lib/
COPY --from=build /lib/*-linux-gnu/libbz2.so.1* /lib/
COPY --from=build /usr/lib/*-linux-gnu/libbz2.so.1* /usr/lib/

# copy built executable
COPY --from=build /app/target/release/microbin /usr/bin/microbin

# copy data directory skeleton with nonroot ownership
COPY --from=build --chown=65532:65532 /app/microbin_data /app/microbin_data

USER 65532:65532

VOLUME ["/app/microbin_data"]

# Expose webport used for the webserver to the docker runtime
EXPOSE 8080

ENTRYPOINT ["/usr/bin/microbin"]
