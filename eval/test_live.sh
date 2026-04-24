#!/bin/bash
# ══════════════════════════════════════════════════════════════
# Live API tests — requires ANTHROPIC_API_KEY
# Tests actual end-to-end agent behavior
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT="$SCRIPT_DIR/../pu.sh"
PASS=0 FAIL=0 TOTAL=0
G='\033[32m' R='\033[31m' B='\033[36m' N='\033[0m'
pass() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf "${G}✓${N} %s — %s\n" "$1" "$2"; }
fail() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); printf "${R}✗${N} %s — %s\n" "$1" "$2"; }

[ -z "${ANTHROPIC_API_KEY:-}" ] && { echo "Set ANTHROPIC_API_KEY to run live tests"; exit 1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
cd "$TMPD"
cp "$AGENT" ./pu.sh
chmod +x ./pu.sh

echo ""
printf "${B}━━━ LIVE: File Creation ━━━${N}\n"

# L1 — Create a file
OUT=$(AGENT_MAX_STEPS=5 AGENT_LOG=l1.jsonl bash ./pu.sh "Create a file called test.txt containing exactly the text 'hello world'. Nothing else." 2>&1)
[ -f test.txt ] && grep -q 'hello world' test.txt \
  && pass "L1" "Creates a file via tool execution" \
  || fail "L1" "Creates a file via tool execution"

# L2 — JSONL log was written
[ -f l1.jsonl ] && jq . l1.jsonl >/dev/null 2>&1 \
  && pass "L2" "JSONL log written with valid JSON" \
  || fail "L2" "JSONL log written with valid JSON"

echo ""
printf "${B}━━━ LIVE: Multi-step Task ━━━${N}\n"

# L3 — Multi-step: create dir, file, read it back
OUT=$(AGENT_MAX_STEPS=10 AGENT_LOG=l3.jsonl bash ./pu.sh "1) Create a directory called mydir. 2) Create mydir/info.txt with the text 'step complete'. 3) Read mydir/info.txt and confirm it exists." 2>&1)
[ -f mydir/info.txt ] && grep -q 'step complete' mydir/info.txt \
  && pass "L3" "Multi-step task (mkdir + write + verify)" \
  || fail "L3" "Multi-step task (mkdir + write + verify)"

# L4 — Multiple tool calls logged
TOOL_CALLS=$(grep -c '"t":"tool_call"' l3.jsonl 2>/dev/null || echo 0)
[ "$TOOL_CALLS" -ge 2 ] \
  && pass "L4" "Multiple tool calls logged ($TOOL_CALLS calls)" \
  || fail "L4" "Multiple tool calls logged ($TOOL_CALLS calls)"

echo ""
printf "${B}━━━ LIVE: Stdin Input ━━━${N}\n"

# L5 — Pipe input
echo "What is 2+2? Reply with just the number." | AGENT_MAX_STEPS=3 AGENT_LOG=l5.jsonl bash ./pu.sh 2>l5.err
# Should get a response (might or might not use tools)
[ -f l5.jsonl ] \
  && pass "L5" "Accepts piped stdin as task" \
  || fail "L5" "Accepts piped stdin as task"

echo ""
printf "${B}━━━ LIVE: Checkpoint Resume ━━━${N}\n"

# L6 — Checkpoint creates file
AGENT_HISTORY=ckpt.json AGENT_MAX_STEPS=3 AGENT_LOG=l6.jsonl bash ./pu.sh "echo hello" 2>/dev/null || true
[ -f ckpt.json ] && [ -s ckpt.json ] \
  && pass "L6" "Checkpoint file created" \
  || fail "L6" "Checkpoint file created"

echo ""
printf "${B}━━━ LIVE TEST RESULTS ━━━${N}\n"
printf "${G}PASS: $PASS${N}  ${R}FAIL: $FAIL${N}  TOTAL: $TOTAL\n"
[ $FAIL -eq 0 ] && exit 0 || exit 1
