# ---------------------------------------------------------------------------
# nartsite — Quartz builder image
# ---------------------------------------------------------------------------
# This image does not serve anything. It runs `quartz build --watch` against
# the Obsidian vault (mounted read-only at /vault) and writes the generated
# site into a volume that the separate `caddy` service serves. See
# docker/entrypoint.sh for how a finished build gets published, and
# compose.yaml for how the volumes are wired together.
#
# Node version is pinned to the exact patch release the repo develops against
# (.node-version and mise.toml both say 22.16.0). Keep all three in sync:
# .npmrc sets engine-strict=true, so if the runtime drifts below the
# "node >=22 / npm >=10.9.2" floor in package.json, `npm ci` fails loudly
# rather than producing a subtly broken install.
FROM node:22.16.0-bookworm-slim

ARG PUBLISH_INTERVAL_SECONDS
ARG SETTLED_BUILD_SECONDS

# System packages, and why each one is here:
#   ca-certificates — HTTPS for the npm registry and for git clones
#   git             — quartz.config.yaml pulls one plugin straight from a repo
#                     (`source: github:quartz-community/fonts`), and the
#                     created-modified-date plugin reads commit history out of
#                     the mounted vault to date pages
#   rsync           — the entrypoint mirrors finished builds into the served
#                     volume with `rsync -a --delete`
#   tini            — PID 1 that forwards signals and reaps children. The
#                     entrypoint backgrounds the quartz process, so without a
#                     real init a `docker stop` would leave it orphaned.
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates git rsync tini \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# --- Dependency layer -------------------------------------------------------
# Copied on its own, before the rest of the source, so that editing a component
# or the Quartz config does not invalidate the (slow) install layer. Only a
# lockfile change rebuilds this.
#
# .npmrc has to come along: it carries engine-strict and legacy-peer-deps, and
# the install behaves differently without it.
#
# Note that NODE_ENV is deliberately left unset. Setting it to "production"
# would make npm skip devDependencies, and the build needs several of them at
# runtime (tsx, esbuild, typescript).
COPY package.json package-lock.json .npmrc ./
RUN npm ci

# --- Source layer -----------------------------------------------------------
# Everything else. .dockerignore keeps out node_modules, the previous build
# output, and the `content` symlink (which points at a host path that does not
# exist inside the image).
COPY . .

# Resolves the plugin list in quartz.config.yaml: clones git-sourced plugins
# into .quartz/plugins/, builds them, and regenerates .quartz/plugins/index.ts
# so quartz.ts can import them. Needs network access at build time.
#
# This is a build step rather than a startup step on purpose — it means a
# container start is just "read content, emit HTML", with no dependency on
# GitHub being reachable at deploy time.
RUN npm run install-plugins

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Healthy once a build has actually been published. The long start period
# covers the initial cold build, which walks the whole vault and resizes
# images — considerably slower than an incremental rebuild.
# /site must match SERVE_DIR in entrypoint.sh.
HEALTHCHECK --interval=30s --timeout=5s --start-period=180s --retries=3 \
  CMD test -s /site/index.html || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
