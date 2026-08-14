#!/usr/bin/env bash
# rebuild.sh – Fully stops, rebuilds, and restarts the entire ecommerce stack.
#
# Usage:
#   ./rebuild.sh                  # Stop, rebuild everything (no-cache), start
#   ./rebuild.sh --skip-tests     # Skip Maven tests (faster)
#   ./rebuild.sh --keep-data      # Preserve named volumes (database data)
#   ./rebuild.sh --no-up          # Build images but do not start containers
#
# This is the canonical "I changed code and want to see it running" script.
# It guarantees fresh JARs inside the Docker images by rebuilding in one pass.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Argument parsing ────────────────────────────────────────────────────────
SKIP_TESTS=false
KEEP_DATA=false
NO_UP=false

for arg in "$@"; do
    case $arg in
        --skip-tests) SKIP_TESTS=true ;;
        --keep-data)  KEEP_DATA=true ;;
        --no-up)      NO_UP=true ;;
    esac
done

echo ""
echo "============================================"
echo "   Ecommerce Platform – Full Rebuild        "
echo "============================================"
echo "Skip tests : $(if $SKIP_TESTS; then echo 'Yes'; else echo 'No'; fi)"
echo "Keep data  : $(if $KEEP_DATA; then echo 'Yes (volumes preserved)'; else echo 'No (volumes removed)'; fi)"
echo "Start stack: $(if $NO_UP; then echo 'No (--no-up)'; else echo 'Yes'; fi)"
echo "============================================"
echo ""

# ─── Step 1: Stop containers ─────────────────────────────────────────────────
echo "[1/4] Stopping running containers..."
if $KEEP_DATA; then
    (cd "$SCRIPT_DIR" && docker compose down --remove-orphans)
else
    # Remove named volumes so databases start fresh (useful when schema changes)
    (cd "$SCRIPT_DIR" && docker compose down --remove-orphans --volumes)
fi
echo ""

# ─── Step 2: Maven builds ────────────────────────────────────────────────────
echo "[2/4] Building Java services (Maven)..."
BUILD_ARGS="--no-docker"  # We handle Docker ourselves below (with --no-cache)
if $SKIP_TESTS; then
    BUILD_ARGS="$BUILD_ARGS --skip-tests"
fi
# shellcheck disable=SC2086
"$SCRIPT_DIR/build-all.sh" $BUILD_ARGS
echo ""

# ─── Step 3: Docker image rebuild (always --no-cache here for full freshness) ─
echo "[3/4] Rebuilding Docker images (no-cache)..."
(cd "$SCRIPT_DIR" && docker compose build --no-cache)
echo ""

# ─── Step 4: Start ───────────────────────────────────────────────────────────
if $NO_UP; then
    echo "[4/4] Skipping container start (--no-up was set)."
else
    echo "[4/4] Starting the stack..."
    (cd "$SCRIPT_DIR" && docker compose up -d)
    echo ""
    echo -e "\e[32mRebuild complete! Stack is starting up.\e[0m"
    echo "Tip: run  docker compose logs -f  to follow logs."
fi
