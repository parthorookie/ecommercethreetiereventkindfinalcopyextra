# ── Stage 1: Builder ──────────────────────────────────────────────────────────
FROM node:18-alpine AS builder

WORKDIR /app

# Copy package files first (critical for layer caching)
COPY package*.json ./

# Use modern and correct flag with npm ci
# npm ci requires package-lock.json to exist
RUN npm ci --omit=dev

# Copy the rest of the application
COPY . .

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
FROM node:18-alpine AS runtime

# Create non-root user for security
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

WORKDIR /app

# Copy only what's needed from builder stage
COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:appgroup /app .

USER appuser

# No EXPOSE needed for worker usually (unless it has HTTP server)
# No HEALTHCHECK for background worker (optional)

CMD ["node", "worker.js"]
