#!/bin/bash
# Run the evaluation suite
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-unit}"

case "$MODE" in
  unit)
    echo "Running behavioral tests (no API calls)..."
    bash test_real.sh
    ;;
  live)
    echo "Running live API tests (requires ANTHROPIC_API_KEY)..."
    bash test_live.sh
    ;;
  all)
    echo "=== Behavioral Tests ==="
    bash test_real.sh
    echo ""
    echo "=== Live Tests ==="
    bash test_live.sh
    ;;
  *)
    echo "Usage: $0 [unit|live|all]"
    echo "  unit  — behavioral tests against actual functions (default, no API)"
    echo "  live  — end-to-end with real API (requires ANTHROPIC_API_KEY)"
    echo "  all   — both"
    exit 1
    ;;
esac
