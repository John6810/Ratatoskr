# syntax=docker/dockerfile:1.7
# Preserve service versions/data formats; refresh their OS security packages.
ARG GO_IMAGE=golang:1.26-bookworm@sha256:d9c68c2c51161e12fd77e4c6320687c9cd86e1af1e3ad6e6cd63ff970641453c
ARG MARIADB_IMAGE=mariadb:11.8@sha256:6422478cb8e159f080fb1d8ccf65101e26fe51385787fde7d16c3b165a331f15
ARG REDIS_IMAGE=redis:7-alpine@sha256:858f009f9709ce576febc734aa78b8f6d624b82571f9ddb6bda4377c833b3499
ARG MEILI_IMAGE=getmeili/meilisearch:v1.43@sha256:4407d9f9a4a5b8ef2e382827782b3dd6e0ecf8f2832ecb0344601691c13da149

FROM --platform=$BUILDPLATFORM ${GO_IMAGE} AS gosu-builder
ARG TARGETOS=linux
ARG TARGETARCH=amd64
WORKDIR /src
RUN git clone --depth 1 --branch 1.19 https://github.com/tianon/gosu.git . \
    && test "$(git rev-parse HEAD)" = 6456aaa0f3c854d199d0f037f068eb97515b7513 \
    && go get github.com/moby/sys/user@v0.4.1 golang.org/x/sys@v0.44.0 \
    && go mod verify \
    && CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -trimpath -ldflags='-s -w' -o /out/gosu .

FROM ${MARIADB_IMAGE} AS mariadb
USER root
RUN apt-get -o APT::Update::Error-Mode=any update \
    && apt-get upgrade -y --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*
# Official entrypoint still drops root via gosu. Rebuild the helper with fixed
# Go dependencies instead of removing it and breaking fresh Compose installs.
COPY --from=gosu-builder --chmod=0755 /out/gosu /usr/local/bin/gosu
RUN gosu mysql id

FROM ${REDIS_IMAGE} AS redis
USER root
RUN apk upgrade --no-cache

FROM ${MEILI_IMAGE} AS meilisearch
USER root
RUN apk upgrade --no-cache && chown -R 65532:65532 /meili_data
USER 65532:65532
