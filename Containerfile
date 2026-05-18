# Multi-stage Erlang build for hecate-llm.
# Pushed to ghcr.io/hecate-services/hecate-llm:latest + :semver.

#----------------------------------------------------------------------
# Stage 1 — builder: full Erlang + rebar3 + deps
#----------------------------------------------------------------------
FROM docker.io/erlang:27-alpine AS builder

RUN apk add --no-cache git build-base

WORKDIR /build
COPY rebar.config rebar.lock ./
COPY src ./src
COPY apps ./apps
COPY config ./config

# Fetch deps + assemble a production release with embedded ERTS.
RUN rebar3 as prod tar

#----------------------------------------------------------------------
# Stage 2 — runtime: slim image, just the release tarball
#----------------------------------------------------------------------
FROM docker.io/alpine:3.20

RUN apk add --no-cache libstdc++ ncurses-libs openssl

WORKDIR /app
COPY --from=builder /build/_build/prod/rel/hecate-llm/*.tar.gz /tmp/release.tar.gz
RUN tar xf /tmp/release.tar.gz && rm /tmp/release.tar.gz

# Realm cert mounts here; service socket mounts under /run/macula.
VOLUME ["/etc/hecate/secrets", "/var/lib/hecate-llm"]

EXPOSE 8470

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget --spider -q http://localhost:8470/health || exit 1

ENTRYPOINT ["/app/bin/hecate-llm"]
CMD ["foreground"]
