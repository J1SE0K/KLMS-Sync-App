FROM node:22-bookworm-slim

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
