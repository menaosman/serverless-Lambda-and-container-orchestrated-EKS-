# ~150-180MB final
FROM node:18-bookworm-slim

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY src ./src

# Healthcheck (basic)
HEALTHCHECK --interval=30s --timeout=3s CMD node -e "process.exit(0)" || exit 1

CMD ["node", "src/index.js"]
