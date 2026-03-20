#!/usr/bin/env bash
# OmniNode SWE-Edition v10 - Setup Script
# Bootstraps the full development environment via Docker Compose

set -euo pipefail

OMNIDEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMNINODE_VERSION="10"
PYTHON_AGENT="$OMNIDEV_DIR/omninode_agent.py"

echo "[INIT] OmniNode SWE-Edition v${OMNINODE_VERSION} Setup"
echo "[DIR]  Working directory: $OMNIDEV_DIR"

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
for cmd in docker curl python3; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Required command not found: $cmd"
    exit 1
  fi
done

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  echo "[ERROR] Neither 'docker compose' nor 'docker-compose' is available."
  exit 1
fi

echo "[CHECK] Using compose command: $COMPOSE_CMD"

# ---------------------------------------------------------------------------
# Write Python orchestrator agent
# ---------------------------------------------------------------------------
cat > "$PYTHON_AGENT" << 'PYEOF'
#!/usr/bin/env python3
"""
OmniNode SWE-Edition v10 - Orchestrator Agent
Continuously polls the Ollama backend and exposes a simple status loop.
"""

import time
import json
import urllib.request
import urllib.error
import sys
import signal
import logging

logging.basicConfig(
    level=logging.INFO,
    format="[%(asctime)s] %(levelname)s %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("omninode")

OLLAMA_URL = "http://localhost:11434/api/tags"
POLL_INTERVAL = 30  # seconds
RUNNING = True


def _sigterm_handler(signum, frame):  # noqa: ARG001
    global RUNNING
    log.info("Received signal %s – shutting down gracefully.", signum)
    RUNNING = False


def fetch_models() -> list[str]:
    """Return list of model names available in Ollama."""
    try:
        with urllib.request.urlopen(OLLAMA_URL, timeout=5) as resp:
            data = json.loads(resp.read())
            return [m["name"] for m in data.get("models", [])]
    except (urllib.error.URLError, json.JSONDecodeError, KeyError) as exc:
        log.warning("Could not reach Ollama: %s", exc)
        return []


def main_loop() -> None:
    signal.signal(signal.SIGTERM, _sigterm_handler)
    signal.signal(signal.SIGINT, _sigterm_handler)

    log.info("OmniNode orchestrator started (poll interval: %ds).", POLL_INTERVAL)
    while RUNNING:
        models = fetch_models()
        if models:
            log.info("Ollama models available: %s", ", ".join(models))
        else:
            log.warning("No models found or Ollama unreachable.")
        time.sleep(POLL_INTERVAL)

    log.info("OmniNode orchestrator stopped.")
    sys.exit(0)


if __name__ == "__main__":
    main_loop()
PYEOF

chmod +x "$PYTHON_AGENT"
echo "[WRITE] Orchestrator agent written to: $PYTHON_AGENT"

# ---------------------------------------------------------------------------
# Build & start stack
# ---------------------------------------------------------------------------
cd "$OMNIDEV_DIR"

echo "[EXEC] Kompiliere und starte Architektur v${OMNINODE_VERSION}…"
$COMPOSE_CMD build
$COMPOSE_CMD up -d

# ---------------------------------------------------------------------------
# Readiness probe – wait for Ollama
# ---------------------------------------------------------------------------
echo "[AWAIT] Initiiere Socket-Readiness-Probe…"
MAX_WAIT=120
ELAPSED=0
until curl -sf http://localhost:11434/api/tags > /dev/null; do
  sleep 2
  ELAPSED=$((ELAPSED + 2))
  if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
    echo "[ERROR] Ollama did not become ready within ${MAX_WAIT}s."
    $COMPOSE_CMD logs ollama
    exit 1
  fi
done

echo "[READY] OmniNode SWE-Edition v${OMNINODE_VERSION} operativ."
echo "[INFO]  Web-IDE  : http://localhost:3000"
echo "[INFO]  Ollama   : http://localhost:11434"
