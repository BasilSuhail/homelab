# The dashboard as a container image, for running it in k3s rather than under
# systemd. Built on the board by buildkit, straight into k3s' own containerd —
# there is no registry and nothing to push to. See
# deploy/install-dashboard-k8s.sh.

FROM node:22-alpine AS build
WORKDIR /src
# Lockfile first: this layer is the slow one and only the lockfile invalidates it.
COPY package.json pnpm-lock.yaml ./
RUN corepack enable && pnpm install --frozen-lockfile
COPY . .
RUN pnpm run build

FROM node:22-alpine
# The client is bundled and the server imports nothing outside the standard
# library, so dist/ is the entire application — no node_modules is copied.
WORKDIR /app
COPY --from=build /src/dist ./dist
# The `node` user ships with the image. Nothing here needs root: the server
# reads its own bundle and talks to the network, and that is all.
USER node
ENV NODE_ENV=production
EXPOSE 8080
CMD ["node", "dist/server.js"]
