# syntax=docker/dockerfile:1
# Reproducible integration-test image for croc.
#
# Both base images are pinned by digest so every machine builds from the
# exact same layers. If the network is unavailable the pull fails loudly;
# nothing here ever falls back to a floating "latest" tag.
#
#   golang:1.27-alpine (multi-arch manifest list)
#   alpine:3.22        (multi-arch manifest list)
ARG GO_IMAGE=golang:1.27-alpine@sha256:4cb7ac979db5fcc41cae44b2227ba5ab8a51e8807f40d9ba4dee20a0ad960b5b
ARG RUNTIME_IMAGE=alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8

FROM ${GO_IMAGE} AS builder

# GOTOOLCHAIN=local: never download a different Go toolchain at build time.
# GOFLAGS=-mod=readonly: never rewrite go.mod/go.sum during the build.
ENV GOTOOLCHAIN=local \
    GOFLAGS=-mod=readonly \
    CGO_ENABLED=0

WORKDIR /build

COPY go.mod go.sum ./
RUN go mod download && go mod verify

COPY . .

# The web client is not part of this test image; recreate the placeholder
# that .dockerignore strips so the go:embed directive stays satisfiable.
RUN mkdir -p src/webassets/dist && touch src/webassets/dist/.gitkeep

# Build the binary under test from this exact commit and prove it runs.
RUN go build -buildvcs=false -trimpath -tags netgo,osusergo \
      -ldflags="-s -w -buildid=" -o /out/croc . \
    && /out/croc --version

FROM ${RUNTIME_IMAGE}

RUN adduser -D croc

COPY --from=builder /out/croc /usr/local/bin/croc
COPY --chmod=0755 deploy/integration-test.sh /usr/local/bin/croc-integration-test

ENV HOME=/home/croc
WORKDIR /home/croc
USER croc
