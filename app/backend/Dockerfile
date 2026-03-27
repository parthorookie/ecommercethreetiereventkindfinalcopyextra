FROM node:18-alpine AS builder

WORKDIR /app

# Copy package files first (better layer caching)
COPY package*.json ./

# IMPORTANT: Use npm ci for reproducible builds (requires package-lock.json)
RUN npm ci --omit=dev

# Copy the rest of the application code
COPY . .

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM node:18-alpine AS runtime

# Security: Create non-root user
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

WORKDIR /app

# Copy only production dependencies and source code from builder
COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:appgroup /app .

USER appuser

EXPOSE 3000

# Healthcheck (optional but good)
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "server.js"]
