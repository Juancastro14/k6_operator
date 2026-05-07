# k6 binary built with the xk6-output-influxdb extension.
# Required because:
#   - k6 v0.50+ removed the built-in --out influxdb=
#   - InfluxDB v3 requires Bearer token auth, which the legacy v1 output never supported
# The xk6-output-influxdb extension speaks v2 line protocol with token auth, which
# InfluxDB v3 accepts via its v2 compatibility endpoint (/api/v2/write).
#
# Pins:
#   - xk6 v0.13.4 (last v0 series; xk6 v1+ defaults to k6 v2 module path which is
#     incompatible with the influxdb extension's go.k6.io/k6 imports)
#   - k6 v0.55.0 (stable v0 series, what the extension was tested against)
#   - xk6-output-influxdb v0.7.0 (latest as of 2026-05)

FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git
ENV CGO_ENABLED=0
RUN go install go.k6.io/xk6/cmd/xk6@v0.13.4
WORKDIR /build
RUN xk6 build v0.55.0 \
      --with github.com/grafana/xk6-output-influxdb@v0.7.0 \
      --output /build/k6

FROM alpine:3.19
RUN apk add --no-cache ca-certificates && \
    adduser -D -u 12345 -g 12345 k6
COPY --from=builder /build/k6 /usr/bin/k6
USER 12345
WORKDIR /home/k6
ENTRYPOINT ["k6"]
