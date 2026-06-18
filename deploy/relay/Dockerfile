FROM node:22-bookworm-slim@sha256:e21fc383b50d5347dc7a9f1cae45b8f4e2f0d39f7ade28e4eef7d2934522b752

ENV NODE_ENV=production \
    KLMS_RELAY_HOST=0.0.0.0 \
    KLMS_RELAY_PORT=18484 \
    KLMS_RELAY_DB=/data/klms-sync-relay.sqlite

WORKDIR /app

COPY tools/klms_relay_server.mjs /app/tools/klms_relay_server.mjs

RUN useradd --system --uid 10001 --create-home --home-dir /home/klms klms \
  && mkdir -p /data \
  && chown -R klms:klms /app /data

USER klms

EXPOSE 18484

CMD ["node", "/app/tools/klms_relay_server.mjs"]
