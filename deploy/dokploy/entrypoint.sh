#!/bin/sh
set -eu

DATA_DIR="${AGENTMEMORY_DATA_DIR:-/data}"
HMAC_FILE="${AGENTMEMORY_HMAC_FILE:-/data/.hmac}"
RUN_AS="node:node"
III_CONFIG="/opt/agentmemory/iii-config.docker.yaml"
AGENTMEMORY_DIR="/opt/agentmemory/node_modules/@agentmemory/agentmemory"

mkdir -p "$DATA_DIR"
chown -R "$RUN_AS" "$DATA_DIR"

# Write iii-config tuned for Docker (0.0.0.0 binding, absolute /data paths)
cat > "$III_CONFIG" <<'EOF'
workers:
  - name: iii-http
    config:
      port: 3111
      host: 0.0.0.0
      default_timeout: 180000
      cors:
        allowed_origins:
          - "http://localhost:3111"
          - "http://localhost:3113"
          - "http://127.0.0.1:3111"
          - "http://127.0.0.1:3113"
          - "https://agentmemory.omnestack.com"
        allowed_methods: [GET, POST, PUT, DELETE, OPTIONS]
  - name: iii-state
    config:
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/state_store.db
  - name: iii-queue
    config:
      adapter:
        name: builtin
  - name: iii-pubsub
    config:
      adapter:
        name: local
  - name: iii-cron
    config:
      adapter:
        name: kv
  - name: iii-stream
    config:
      port: 3112
      host: 0.0.0.0
      adapter:
        name: kv
        config:
          store_method: file_based
          file_path: /data/stream_store
  - name: iii-observability
    config:
      enabled: true
      service_name: agentmemory
      exporter: memory
      sampling_ratio: 1.0
      metrics_enabled: true
      logs_enabled: true
      logs_console_output: true
EOF
chown "$RUN_AS" "$III_CONFIG"

# Generate HMAC secret on first boot
if [ ! -s "$HMAC_FILE" ]; then
  SECRET="$(openssl rand -hex 32)"
  umask 077
  printf '%s\n' "$SECRET" > "$HMAC_FILE"
  chmod 600 "$HMAC_FILE"
  chown "$RUN_AS" "$HMAC_FILE"
fi

AGENTMEMORY_SECRET="$(cat "$HMAC_FILE")"
export AGENTMEMORY_SECRET

# Pre-create preferences so the worker skips interactive onboarding
PREFS_DIR="$DATA_DIR/.agentmemory"
PREFS_FILE="$PREFS_DIR/preferences.json"
mkdir -p "$PREFS_DIR"
cat > "$PREFS_FILE" <<EOF
{"skipSplash":true,"skipNpxHint":true,"skipGlobalInstall":true,"skipConsoleInstall":true,"firstRunAt":"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"}
EOF
touch "$PREFS_DIR/.env"
chown -R "$RUN_AS" "$PREFS_DIR"

# Export env so worker does not try relative ./data paths
export HOME="$DATA_DIR"
export PATH="/usr/local/bin:$PATH"

wait_for_port() {
  local host=$1 port=$2 timeout=${3:-30}
  local elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    if curl -sS --connect-timeout 1 "http://${host}:${port}/" > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

# ── Start iii-engine in the background ──
echo "[entrypoint] Starting iii-engine..."
gosu "$RUN_AS" iii -c "$III_CONFIG" &
III_PID=$!

echo "[entrypoint] Waiting for iii-engine on port 3111..."
if ! wait_for_port 127.0.0.1 3111 30; then
  echo "[entrypoint] ERROR: iii-engine did not become ready within 30s"
  kill "$III_PID" 2>/dev/null || true
  exit 1
fi
echo "[entrypoint] iii-engine ready (PID $III_PID)"

# Start agentmemory worker in the background
echo "[entrypoint] Starting agentmemory worker module..."
cd "$AGENTMEMORY_DIR"
gosu "$RUN_AS" node "$AGENTMEMORY_DIR/dist/index.mjs" &
WORKER_PID=$!

cleanup() {
  echo "[entrypoint] Shutting down..."
  kill -TERM "$WORKER_PID" 2>/dev/null || true
  kill -TERM "$III_PID" 2>/dev/null || true
  wait "$WORKER_PID" 2>/dev/null || true
  wait "$III_PID" 2>/dev/null || true
  exit 0
}
trap cleanup TERM INT

# Monitor: if engine dies, kill worker and exit
monitor_engine() {
  while kill -0 "$III_PID" 2>/dev/null; do
    sleep 3
  done
  echo "[entrypoint] iii-engine died; killing worker..."
  kill -TERM "$WORKER_PID" 2>/dev/null || true
}
monitor_engine &

# Block on worker (the primary concern)
wait "$WORKER_PID"
WORKER_EXIT=$?
echo "[entrypoint] Worker exited with code $WORKER_EXIT"
cleanup
