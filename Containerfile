# Multi-stage Erlang build for hecate-llm.
# Pushed to ghcr.io/hecate-services/hecate-llm:latest + :semver.

#----------------------------------------------------------------------
# Stage 1 — builder: full Erlang + rebar3 + deps
#----------------------------------------------------------------------
FROM docker.io/erlang:27-alpine AS builder

# openssl-dev/zstd-dev/snappy-dev/lz4-dev: hecate_om pulls in rocksdb (via
# barrel_docdb) and khepri/ra transitively, UNCONDITIONALLY -- confirmed
# live 2026-09-02, this build failed at "rebar3 as prod tar" with CMake's
# "Could NOT find OpenSSL" without these, exactly the same gap
# hecate-mail's own Containerfile already documents hitting first. Not
# specific to a service that owns its own reckon-db store.
RUN apk add --no-cache \
    git curl bash \
    build-base cmake \
    perl linux-headers \
    openssl-dev zstd-dev snappy-dev lz4-dev

# Rust via rustup (reckon_db 2.x ships NIFs and hecate_om transitively
# pulls macula_quic, also a Rust NIF; Alpine's rustc is too old for
# their deps).
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
        | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"
# musl-targeted rustup defaults to crt-static; cdylib NIFs need it off.
ENV RUSTFLAGS="-C target-feature=-crt-static"
# macula ships a QUIC NIF. Makes it build here rather than fetch a
# prebuilt binary linked against a different libc -- the recorded glibc
# trap: the fetched artifact loads on the build host and fails on
# alpine at runtime.
ENV MACULA_FORCE_SOURCE_BUILD=1

WORKDIR /build
COPY rebar.config ./
COPY src ./src
COPY apps ./apps
COPY config ./config

# Fetch deps + assemble a production release with embedded ERTS.
RUN rebar3 as prod tar

#----------------------------------------------------------------------
# Stage 2 — runtime: slim image, just the release tarball
#----------------------------------------------------------------------
# MUST match the builder's OWN Alpine base (erlang:27-alpine ships Alpine
# 3.22.5, confirmed live via `docker run erlang:27-alpine cat
# /etc/alpine-release`), not an independently-picked version. Erlang's
# `crypto` app dlopen's the SYSTEM libcrypto/libssl at boot rather than
# bundling its own (even with relx's include_erts:true, which only
# embeds ERTS itself) -- confirmed live on the actual beam00 deploy
# target, not just locally: 3.20's older OpenSSL is missing a symbol
# (EVP_MD_CTX_get_size_ex) the crypto NIF built against 3.22's newer one
# needs, so `kernel` itself fails application on_load and the whole
# release crash-loops before ever reaching macula_om's own logging, let
# alone advertising a single capability.
FROM docker.io/alpine:3.22

# zstd-libs/snappy/lz4-libs: the RUNTIME shared libraries for rocksdb's
# compression backends, compiled against in the builder stage above via
# their -dev packages. Missing here crashes the release outright on
# boot -- rocksdb's on_load NIF init fails with "Failed to load NIF
# library: Error loading shared library liblz4.so.1: No such file or
# directory" and the whole node exits -- same failure hecate-mail's own
# Containerfile documents hitting once already; not re-discovering it
# live here, just not repeating it.
RUN apk add --no-cache libstdc++ ncurses-libs openssl ca-certificates \
    zstd-libs snappy lz4-libs

WORKDIR /app
COPY --from=builder /build/_build/prod/rel/hecate_llm/*.tar.gz /tmp/release.tar.gz
RUN tar xf /tmp/release.tar.gz && rm /tmp/release.tar.gz

ENV HOME=/app
ENV RELX_REPLACE_OS_VARS=true

# Realm cert mounts here; service socket mounts under /run/macula.
VOLUME ["/etc/hecate/secrets", "/var/lib/hecate-llm"]

EXPOSE 8470

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --spider -q http://localhost:8470/health || exit 1

ENTRYPOINT ["/app/bin/hecate_llm"]
CMD ["foreground"]
