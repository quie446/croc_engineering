# syntax=docker/dockerfile:1

# Integration-test image for croc. Base images are pinned by tag AND digest so
# every machine builds from byte-identical layers. Bump tag and digest together
# with:
#   docker buildx imagetools inspect golang:1.27-alpine --format '{{.Manifest.Digest}}'
#   docker buildx imagetools inspect alpine:3.21 --format '{{.Manifest.Digest}}'
# Never float these on `latest`: if the network is gone the build must fail
# loudly, not silently resolve something else.
ARG GO_IMAGE=golang:1.27-alpine@sha256:4cb7ac979db5fcc41cae44b2227ba5ab8a51e8807f40d9ba4dee20a0ad960b5b
ARG RUNTIME_IMAGE=alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507

FROM ${GO_IMAGE} AS builder
# GOTOOLCHAIN=local: never silently download a different Go toolchain.
ENV GOTOOLCHAIN=local \
    GOFLAGS=-mod=readonly \
    CGO_ENABLED=0
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download && go mod verify
COPY . .
ARG GIT_REVISION=unknown
RUN go build -buildvcs=false -trimpath -tags netgo,osusergo \
      -ldflags="-s -w -buildid=" -o /out/croc . \
    && printf '%s' "${GIT_REVISION}" > /out/REVISION

# Unit-test stage: full Go toolchain + this commit's source. Tests only ever
# exercise the code built here, never a host croc or a `go install`ed one.
FROM builder AS tester
RUN cp deploy/it/unit-tests.sh /usr/local/bin/it-unit-tests.sh \
    && chmod +x /usr/local/bin/it-unit-tests.sh
ENTRYPOINT ["/usr/local/bin/it-unit-tests.sh"]

# Runtime stage: the croc binary plus the e2e harness. No apk additions, so
# busybox (nc, timeout, sha256sum) is the only userland and comes from the
# pinned alpine digest.
FROM ${RUNTIME_IMAGE} AS runtime
COPY --from=builder /out/croc /usr/local/bin/croc
COPY --from=builder /out/REVISION /etc/croc-it-revision
COPY deploy/it/e2e.sh /usr/local/bin/it-e2e.sh
RUN chmod +x /usr/local/bin/it-e2e.sh
ENTRYPOINT ["/usr/local/bin/croc"]
CMD ["--help"]
