# syntax=docker/dockerfile:1

ARG RUST_VERSION=1.98.0
FROM rust:${RUST_VERSION}-bookworm AS build

ARG CARGO_LEPTOS_VERSION=0.3.7
# Empty means all CPUs available to the builder. Set this on small machines.
ARG BUILD_JOBS

ENV SQLX_OFFLINE=true \
    CARGO_HOME=/cache/cargo \
    CARGO_TARGET_DIR=/cache/target \
    XDG_CACHE_HOME=/cache/tools \
    LEPTOS_SITE_ROOT=/out/site \
    PATH=/opt/cargo-tools/bin:$PATH

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates clang cmake git libssl-dev pkg-config \
    && rm -rf /var/lib/apt/lists/* \
    && rustup target add wasm32-unknown-unknown

# Install the build tool before copying application sources. Keep its binary
# outside the cache mount so this layer is sufficient on a fresh builder.
# The linker override is stable only on x86_64 Linux. Keep ARM64 on its
# default linker, and never pass this override to the WASM app.
ARG TARGETARCH
RUN --mount=type=cache,target=/cache,sharing=locked \
    export CARGO_BUILD_JOBS="${BUILD_JOBS:-$(nproc)}" \
    && jas_tool_rustflags="" \
    && case "$TARGETARCH" in amd64) jas_tool_rustflags="-C linker-features=-lld" ;; esac \
    && RUSTFLAGS="$jas_tool_rustflags" cargo install \
       --locked --version "${CARGO_LEPTOS_VERSION}" \
       --root /opt/cargo-tools --target-dir /tmp/jas-cargo-leptos-build cargo-leptos \
    && rm -rf /tmp/jas-cargo-leptos-build

WORKDIR /src
COPY Cargo.toml Cargo.lock build.rs ./
COPY .sqlx/ .sqlx/
COPY migrations/ migrations/
COPY src/ src/
COPY style/ style/
COPY public/ public/

# build.rs embeds these values; introduce them after the expensive tool layer.
ARG GITHUB_SHA
ARG GITHUB_RUN_NUMBER
ARG GITHUB_REF_NAME

# /cache is also restored/saved by the Docker GitHub Actions workflow.
# Copy the finished binary OUT of the cache mount before the RUN ends.
RUN --mount=type=cache,target=/cache,sharing=locked \
    export CARGO_BUILD_JOBS="${BUILD_JOBS:-$(nproc)}" \
    && cargo leptos build --release \
       --bin-cargo-args=--locked --lib-cargo-args=--locked \
    && install -D -m 0755 /cache/target/release/jas /out/jas

FROM debian:bookworm-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates libgcc-s1 libssl3 openssl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 10001 jas \
    && useradd --uid 10001 --gid jas --no-create-home --home-dir /data jas \
    && install -d -o jas -g jas -m 0700 /data /data/ipas

WORKDIR /app
COPY --from=build /out/jas /app/jas
COPY --from=build /out/site/ /app/site/
# Runtime configuration is bind-mounted by Compose.
RUN mkdir -p /etc/jas
COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/jas-entrypoint

ENV LEPTOS_OUTPUT_NAME=jas \
    LEPTOS_SITE_ROOT=/app/site \
    LEPTOS_SITE_PKG_DIR=pkg \
    LEPTOS_ENV=PROD \
    JAS_CONFIG=/etc/jas/jas.toml

USER 10001:10001
ENTRYPOINT ["/usr/local/bin/jas-entrypoint"]
CMD ["/app/jas"]
