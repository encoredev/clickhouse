# The ClickHouse image Encore runs where it runs ClickHouse in Docker, as on
# Windows: ClickHouse's official server image of the same release, with its
# binary replaced by Encore's build of it (encore/dist.sh), which has
# CREATE DATABASE ... CLONE AS and SYSTEM BRANCH. Everything else is the
# official image's: the entrypoint and the environment variables it reads,
# the configuration, the ports and the volume. Every clickhouse-* command in
# it is a link to /usr/bin/clickhouse.
#
# The build context holds the outputs of encore/dist.sh for linux-amd64 and
# linux-arm64, as linux-amd64/ and linux-arm64/:
#
#   docker buildx build --platform linux/amd64,linux/arm64 \
#       -f encore/docker/Dockerfile <context>
#
# Nothing runs in the image while it is built, so either platform builds on
# any host. encore/docker/check.sh checks an image.

# The official image of the release this branch is of, pinned.
FROM clickhouse/clickhouse-server:26.10@sha256:9c55d8d8a77e03e1fd399d59e4d0a1c7a5e42df70098ff1c5d8bd18eb1a5d106

ARG TARGETARCH

COPY linux-${TARGETARCH}/bin/clickhouse /usr/bin/clickhouse
COPY linux-${TARGETARCH}/LICENSE linux-${TARGETARCH}/VERSION /usr/share/doc/clickhouse-encore/

LABEL org.opencontainers.image.source="https://github.com/encoredev/clickhouse" \
      org.opencontainers.image.description="ClickHouse with CREATE DATABASE ... CLONE AS and SYSTEM BRANCH, as Encore runs it" \
      org.opencontainers.image.licenses="Apache-2.0"
