# Node.js service: production dependencies only, root-owned app files, runs as UID 1000 (the image's "node" user).
# CHANGE: base tag; keep every stage on the same one.
FROM node:24.21.0-alpine3.24 AS base
WORKDIR /app

# --ignore-scripts blocks dependency install scripts; drop it only if a native module needs its postinstall.
# mkdir: with zero runtime dependencies npm creates no node_modules and the COPY below would fail.
FROM base AS deps
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci --omit=dev --ignore-scripts && mkdir -p node_modules

FROM base AS build
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
# CHANGE: build script; its output directory is copied below
RUN npm run build

FROM base AS runtime
ENV NODE_ENV=production
COPY --from=deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY package.json ./
USER 1000:1000
# CHANGE: listen port (>= 1024 as non-root)
EXPOSE 8080
# node runs as PID 1: the app must handle SIGTERM itself, or it is killed when the grace period ends.
# CHANGE: entry file
CMD ["node", "dist/server.js"]
