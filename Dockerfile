FROM --platform=$BUILDPLATFORM golang:1.26.5-alpine3.23@sha256:622e56dbc11a8cfe87cafa2331e9a201877271cbff918af53d3be315f3da88cc AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY cmd ./cmd
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=1.0.0
RUN CGO_ENABLED=0 GOOS="$TARGETOS" GOARCH="$TARGETARCH" go build -buildvcs=false -trimpath -ldflags="-s -w -X main.version=$VERSION" -o /service ./cmd/service

FROM gcr.io/distroless/static-debian12:nonroot@sha256:afa5c872c891853ca7fcf1f12c3edb23f7eeef36189728842dd51042ff57f7ab
ARG VERSION=1.0.0
ARG REVISION=local
LABEL org.opencontainers.image.title="DevOps assessment service" org.opencontainers.image.version="$VERSION" org.opencontainers.image.revision="$REVISION"
COPY --from=build /service /service
USER 65532:65532
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s --retries=3 CMD ["/service","healthcheck"]
ENTRYPOINT ["/service"]
