#!/bin/bash
set -e

# Mirror dashboard-ref-only's startup: create every directory hermes expects
# and seed a default config.yaml if the volume is empty. Without these,
# `hermes dashboard` endpoints that hit logs/, sessions/, cron/, etc. can fail
# with opaque errors even though no auth is actually involved.
mkdir -p /data/.hermes/cron /data/.hermes/sessions /data/.hermes/logs \
         /data/.hermes/memories /data/.hermes/skills /data/.hermes/pairing \
         /data/.hermes/hooks /data/.hermes/image_cache /data/.hermes/audio_cache \
         /data/.hermes/workspace /data/.hermes/skins /data/.hermes/plans \
         /data/.hermes/home

if [ ! -f /data/.hermes/config.yaml ] && [ -f /opt/hermes-agent/cli-config.yaml.example ]; then
  cp /opt/hermes-agent/cli-config.yaml.example /data/.hermes/config.yaml
fi

[ ! -f /data/.hermes/.env ] && touch /data/.hermes/.env

# Bootstrap OAuth tokens from env var (e.g. xAI Grok SuperGrok).
# Set HERMES_AUTH_JSON_BOOTSTRAP to the contents of a locally-generated
# ~/.hermes/auth.json. Written only once — subsequent token refreshes update
# the file in place on the persistent volume.
if [ ! -f /data/.hermes/auth.json ] && [ -n "${HERMES_AUTH_JSON_BOOTSTRAP}" ]; then
  printf '%s' "${HERMES_AUTH_JSON_BOOTSTRAP}" > /data/.hermes/auth.json
  chmod 600 /data/.hermes/auth.json
fi

# Clear any stale gateway PID file left over from the previous container.
# `hermes gateway` writes /data/.hermes/gateway.pid on start but does not
# remove it on SIGTERM. Since /data is a persistent volume, the file
# survives container restarts and causes every subsequent boot to exit with
# "ERROR gateway.run: PID file race lost to another gateway instance".
# No hermes process can be running at this point (we're pre-exec in a fresh
# container), so removing the file unconditionally is safe.
rm -f /data/.hermes/gateway.pid

# Start Chromium for browser-harness before starting the app.
echo "Starting Chromium for browser-harness..."

export BU_CDP_URL="${BU_CDP_URL:-http://127.0.0.1:9222}"
export CHROME_USER_DATA_DIR="${CHROME_USER_DATA_DIR:-/data/.browser-harness-profile}"

CHROME_BIN="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"

if [ -z "$CHROME_BIN" ]; then
  echo "ERROR: Chromium/Chrome not found. Check Dockerfile apt-get install chromium."
  exit 1
fi

mkdir -p "$CHROME_USER_DATA_DIR"

# Remove stale Chromium profile locks from previous Railway containers.
# These files can remain in the persistent volume and make Chromium think
# the profile is already in use, preventing it from starting.
echo "Removing stale Chromium lock files from $CHROME_USER_DATA_DIR..."

rm -f "$CHROME_USER_DATA_DIR/SingletonLock" \
      "$CHROME_USER_DATA_DIR/SingletonCookie" \
      "$CHROME_USER_DATA_DIR/SingletonSocket"

"$CHROME_BIN" \
  --headless=new \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9222 \
  --user-data-dir="$CHROME_USER_DATA_DIR" \
  --no-sandbox \
  --disable-dev-shm-usage \
  --no-first-run \
  --no-default-browser-check \
  about:blank &
  

echo "Waiting for Chromium CDP at $BU_CDP_URL..."

for i in {1..30}; do
  if curl -fsS "$BU_CDP_URL/json/version" >/dev/null; then
    echo "Chromium CDP is ready"
    break
  fi
  sleep 1
done

if ! curl -fsS "$BU_CDP_URL/json/version" >/dev/null; then
  echo "ERROR: Chromium CDP did not start"
  exit 1
fi

exec python /app/server.py