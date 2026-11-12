# Static site / SPA: built with Node, served by nginx-unprivileged (UID 101, port 8080, PID and temp files in /tmp).
# CHANGE: Node tag for the build
FROM node:24.21.0-alpine3.24 AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN --mount=type=cache,target=/root/.npm npm ci
COPY . .
# CHANGE: build script; its output directory is copied below
RUN npm run build

# CHANGE: nginx tag (stable branch)
FROM nginxinc/nginx-unprivileged:1.30.5-alpine
# Server block: tooling/network/nginx/static-site.conf (listens on 8080, SPA fallback, cache headers).
COPY static-site.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
USER 101:101
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
