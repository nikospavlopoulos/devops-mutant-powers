# Go service: static binary built on golang:alpine, shipped in scratch (no shell, no package manager); UID 65532.
# CHANGE: Go toolchain tag (match the go directive in go.mod)
FROM golang:1.27.1-alpine3.24 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
# Set by buildx from --platform; CGO_ENABLED=0 gives a static binary that runs in scratch.
ARG TARGETOS
ARG TARGETARCH
# CHANGE: main package path
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -trimpath -ldflags="-s -w" -o /out/app ./cmd/app

FROM scratch
# scratch has no CA bundle; outbound TLS needs this. Time zones: build with -tags timetzdata.
COPY --from=build /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=build /out/app /app
USER 65532:65532
# CHANGE: listen port
EXPOSE 8080
ENTRYPOINT ["/app"]
