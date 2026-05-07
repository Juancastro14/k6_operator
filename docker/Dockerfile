# k6 binary built with the xk6-output-influxdb extension.
# Required because:
#   - k6 v0.50+ removed the built-in --out influxdb=
#   - InfluxDB v3 requires Bearer token auth, which the legacy v1 output never supported
# The xk6-output-influxdb extension speaks v2 line protocol with token auth, which
# InfluxDB v3 accepts via its v2 compatibility endpoint (/api/v2/write).

FROM grafana/xk6:latest AS builder
WORKDIR /build
RUN xk6 build \
      --with github.com/grafana/xk6-output-influxdb@latest \
      --output /build/k6

FROM alpine:3.19
RUN apk add --no-cache ca-certificates && \
    adduser -D -u 12345 -g 12345 k6
COPY --from=builder /build/k6 /usr/bin/k6
USER 12345
WORKDIR /home/k6
ENTRYPOINT ["k6"]
