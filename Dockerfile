# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — deps
#   Install ALL dependencies (including devDependencies) so we can run tests
#   and produce a clean, auditable dependency tree before the final image.
# ─────────────────────────────────────────────────────────────────────────────
FROM node:18-alpine AS deps

# Install libc compatibility shims sometimes needed by native add-ons on Alpine.
# Also ca-certificates for any outbound HTTPS calls at build time.
RUN apk add --no-cache libc6-compat ca-certificates

WORKDIR /app

# Copy manifests first — Docker cache busts here only when they change.
COPY package.json package-lock.json ./

# ci: deterministic, respects lock-file, skips optional non-essential scripts.
RUN npm ci


# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — test
#   Run the Jest suite inside the image so a failing test aborts the build.
#   Nothing from this stage is carried forward to production.
# ─────────────────────────────────────────────────────────────────────────────
FROM deps AS test

COPY . .

RUN npm test


# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 — production
#   Re-install only production dependencies, copy application source, and
#   harden the runtime: non-root user, read-only filesystem where possible.
# ─────────────────────────────────────────────────────────────────────────────
FROM node:18-alpine AS production

# Update base packages to pick up any security patches in the Alpine layer.
RUN apk add --no-cache ca-certificates \
    && apk upgrade --no-cache

WORKDIR /app

# Copy manifests and install production dependencies only.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev \
    # Remove npm cache to keep the layer lean.
    && npm cache clean --force

# Copy application source (excludes everything in .dockerignore).
COPY src/ ./src/

# Create the logs directory with correct ownership before switching users.
# The app writes to logs/ at runtime; we own it as node so no root is needed.
RUN mkdir -p logs \
    && chown -R node:node /app

# ── Non-root user ─────────────────────────────────────────────────────────────
# The official node image ships a built-in "node" user (uid 1000 / gid 1000).
USER node

# ── Runtime environment ───────────────────────────────────────────────────────
ENV NODE_ENV=production \
    PORT=3000

EXPOSE 3000

# ── Healthcheck ───────────────────────────────────────────────────────────────
# Docker (and Compose v2 / Swarm) will mark the container unhealthy if GET
# /health stops returning 2xx, enabling automatic restarts.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:3000/health || exit 1

# ── Entrypoint ────────────────────────────────────────────────────────────────
# Use the exec form (JSON array) so Node receives SIGTERM directly — no shell
# wrapper means no extra process to relay signals, allowing graceful shutdown.
CMD ["node", "src/app.js"]
