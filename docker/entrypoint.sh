#!/bin/sh
# ---------------------------------------------------------------------------
# nartsite — Quartz build + publish loop
# ---------------------------------------------------------------------------
# Two things run here:
#
#   1. `quartz build --watch`, in the background. It does one full build, then
#      stays alive watching CONTENT_DIR and doing incremental rebuilds whenever
#      the Obsidian sync container writes into the vault.
#
#   2. A publish loop, in the foreground. It waits for the build output to look
#      finished, then mirrors it into SERVE_DIR with rsync.
#
# Why the two directories instead of letting quartz write straight into the
# directory caddy serves:
#
#   A full `quartz build` starts by deleting its own output directory
#   (quartz/build.ts). If caddy were pointed at that directory, every restart
#   of this container would blank the live site for the whole length of the
#   cold build. With the split, SERVE_DIR keeps serving the previous deploy —
#   it is a named volume, so it survives the restart — and only gets
#   overwritten once a complete new build exists. Redeploys stay seamless.
#
#   It also sidesteps an EBUSY: that same `rm -rf` fails when the output
#   directory is a mount point, which BUILD_DIR would have to be otherwise.
# ---------------------------------------------------------------------------

# Exit on error and error on unset variables
set -eu

# Define log helper which prefixes all log messages with [publish]
log() { echo "[publish] $*"; }

# Fail fast and loudly on a misconfigured mount. Without this check quartz
# would start, find no content, and cheerfully publish an empty site over a
# perfectly good previous deploy.
if [ ! -d "${QUARTZ_CONTENT_DIR}" ]; then
  echo "[publish] content directory ${QUARTZ_CONTENT_DIR} does not exist — is the vault volume mounted?" >&2
  exit 1
fi
log "content directory ${QUARTZ_CONTENT_DIR} exists — vault volume is mounted"

# Create build and serve directories
mkdir -p "$QUARTZ_BUILD_DIR" "$QUARTZ_SERVE_DIR"

# Background the builder and keep its PID: the loop below uses it both as a
# liveness check and as the process to forward shutdown signals to.
node ./quartz/bootstrap-cli.mjs build \
  --watch \
  --directory "$QUARTZ_CONTENT_DIR" \
  --output "$QUARTZ_BUILD_DIR" &
quartz_pid=$!

# `docker stop` sends SIGTERM to tini, which forwards it here. Pass it on to
# quartz so it shuts its file watchers down instead of being SIGKILLed after
# the grace period.
trap 'kill -TERM "$quartz_pid" 2>/dev/null || true; exit 0' TERM INT

# Is the current build output safe to publish?
#
# Quartz has no "build finished" hook to hang this off, so this infers it:
# index.html exists and is non-empty, and nothing under QUARTZ_BUILD_DIR has been
# written for SETTLED_BUILD_SECONDS. Emitters write files progressively, so without the
# quiet check the loop could catch a build mid-flight and publish a site whose
# pages reference stylesheets that have not been emitted yet.
build_settled() {
  [ -s "$QUARTZ_BUILD_DIR/index.html" ] || return 1
  # -print -quit stops at the first match, so this stays cheap; empty output
  # means nothing was modified inside the window.
  [ -z "$(find "$QUARTZ_BUILD_DIR" -newermt "-${SETTLED_BUILD_SECONDS} seconds" -print -quit 2>/dev/null)" ]
}

published=0    # has anything been published since this container started?
last_stamp=""  # newest mtime in BUILD_DIR as of the last publish

while kill -0 "$quartz_pid" 2>/dev/null; do
  sleep "$PUBLISH_INTERVAL_SECONDS"

  # Mid-build, or no build yet — check again next tick.
  build_settled || continue

  # Newest mtime across the build output, used as a cheap content fingerprint.
  # In the steady state nothing changes between ticks, so this lets the loop
  # skip the rsync entirely rather than re-walking the tree every couple of
  # seconds.
  stamp="$(find "$QUARTZ_BUILD_DIR" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1)"
  [ "$stamp" = "$last_stamp" ] && [ "$published" -eq 1 ] && continue

  # -a preserves timestamps, which matters: caddy derives Last-Modified and
  # ETag from them, so preserving them keeps client caches valid across a
  # rebuild that did not actually change a given file. --delete prunes pages
  # deleted from the vault.
  rsync -a --delete "$QUARTZ_BUILD_DIR/" "$QUARTZ_SERVE_DIR/"

  # Update the last stamp
  last_stamp="$stamp"

  # Update the published flag
  if [ "$published" -eq 0 ]; then
    published=1
    log "first build published to $QUARTZ_SERVE_DIR"
  else
    log "republished to $QUARTZ_SERVE_DIR"
  fi
done

# Quartz exited on its own — surface its exit status so the container dies too
# and compose's `restart: unless-stopped` brings the stack back up. Without
# this the container would linger with a dead builder, serving a frozen site.
wait "$quartz_pid"
