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
  structure)
    echo "Running structure tests (grep-based smoke checks)..."
    bash test_agent.sh
    ;;
  live)
    echo "Running live API tests (requires ANTHROPIC_API_KEY)..."
    bash test_live.sh
    ;;
  all)
    echo "=== Behavioral Tests ==="
    bash test_real.sh
    echo ""
    echo "=== Structure Tests ==="
    bash test_agent.sh
    echo ""
    echo "=== Live Tests ==="
    bash test_live.sh
    ;;
  *)
    echo "Usage: $0 [unit|structure|live|all]"
    echo "  unit       — behavioral tests against actual functions (default)"
    echo "  structure  — grep-based smoke checks"
    echo "  live       — end-to-end with real API"
    echo "  all        — all three"
    exit 1
    ;;
esac
