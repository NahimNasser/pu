#!/bin/bash
# Run the evaluation suite
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-unit}"

case "$MODE" in
  unit)
    echo "Running unit tests (no API calls)..."
    bash test_agent.sh
    ;;
  live)
    echo "Running live API tests (requires ANTHROPIC_API_KEY)..."
    bash test_live.sh
    ;;
  all)
    echo "=== Unit Tests ==="
    bash test_agent.sh
    echo ""
    echo "=== Live Tests ==="
    bash test_live.sh
    ;;
  *)
    echo "Usage: $0 [unit|live|all]"
    exit 1
    ;;
esac
