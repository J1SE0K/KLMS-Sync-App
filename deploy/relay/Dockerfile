FROM debian:bookworm-slim@sha256:7b140f374b289a7c2befc338f42ebe6441b7ea838a042bbd5acbfca6ec875818 AS data-layout

RUN mkdir /data && chown 65532:65532 /data

FROM gcr.io/distroless/nodejs22-debian13@sha256:a2723a2817c5b01b8e7b98d567bc8b5a6b0e713e25bfb0a82b6ade4b9db06f50

ENV NODE_ENV=production \
    KLMS_RELAY_HOST=0.0.0.0 \
    KLMS_RELAY_PORT=18484 \
    KLMS_RELAY_DB=/data/klms-sync-relay.sqlite

WORKDIR /app

COPY --from=data-layout --chown=65532:65532 /data /data

COPY --chown=65532:65532 \
     tools/klms_relay_server.mjs \
     tools/klms_bounded_rate_window.mjs \
     tools/klms_public_log_redactor.mjs \
     tools/klms_realtime_admission.mjs \
     /app/tools/

USER 65532

EXPOSE 18484

CMD ["/app/tools/klms_relay_server.mjs"]
