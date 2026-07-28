FROM node:24-trixie-slim

RUN apt update && apt install -y curl jq

# Install OpenClaw, PM2, Express, and ws globally
# ws is required by index.js to speak the OpenClaw Gateway WebSocket protocol
# (agent -> agent.wait -> sessions.history) instead of the fire-and-forget CLI.
RUN npm install -g openclaw@latest pm2@latest express@latest ws@latest

# Tell Node.js where to find global modules so index.js can require('express')
ENV NODE_PATH=/usr/local/lib/node_modules

WORKDIR /app

# PM2 runtime keeps the container alive and monitors the apps
CMD ["pm2-runtime", "ecosystem.config.js"]

