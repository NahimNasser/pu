#!/bin/bash
# Behavioral tests for pu.sh — sources the actual functions and validates
# real outputs against Python's json parser. Catches what grep-based tests miss.
#
# Regression coverage:
#   - json_escape control-char handling   (commit 65f6728)
#   - jp/jb brace-in-string handling (commit 80fdf9f)
#   - trim_context end-to-end correctness (commit 6adc939)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT="${AGENT:-$SCRIPT_DIR/../pu.sh}"
PASS=0 FAIL=0 TOTAL=0
G='\033[32m' R='\033[31m' B='\033[36m' N='\033[0m'
pass(){ PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); printf "${G}✓${N} %-6s %s\n" "$1" "$2"; }
fail(){ FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); printf "${R}✗${N} %-6s %s\n" "$1" "$2"; [ -n "${3:-}" ] && printf "         %s\n" "$3"; }
valid_json(){ printf '%s' "$1" | python3 -m json.tool >/dev/null 2>&1; }
json_field(){ printf '%s' "$1" | python3 -c "import sys,json; d=json.load(sys.stdin); $2"; }

TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
# Source pu.sh up to (but not including) the main entry point, so all functions
# get defined without running the agent loop.
sed -n '/^TASK=""/q;p' "$AGENT" > "$TMPD/funcs.sh"
# shellcheck disable=SC1091
. "$TMPD/funcs.sh" >/dev/null 2>&1 || true
set +u; HISTORY=

# ── json_escape: control chars + round-trip ────────────────────────
echo
printf "${B}━━━ json_escape ━━━${N}\n"

ESC=$(json_escape "$(printf 'has\rCR')")
valid_json "$(printf '{"x":"%s"}' "$ESC")" \
  && pass "JE-1" "carriage return → valid JSON" \
  || fail "JE-1" "CR escape" "got: $(printf '%s' "$ESC" | od -c | head -1)"

ESC=$(json_escape "$(printf 'a\x01b\x02c\x05d')")
valid_json "$(printf '{"x":"%s"}' "$ESC")" \
  && pass "JE-2" "raw control bytes (0x01-0x05) sanitized" \
  || fail "JE-2" "raw control bytes" "got: $ESC"

ESC=$(json_escape "$(printf 'a\bb\fc\vd')")
valid_json "$(printf '{"x":"%s"}' "$ESC")" \
  && pass "JE-3" "backspace, formfeed, vtab sanitized" \
  || fail "JE-3" "BS/FF/VT" "got: $ESC"

# Round-trip: original bytes recoverable through escape → JSON parse
INPUT=$'line1\nline2\tafter-tab\n  end'
ESC=$(json_escape "$INPUT")
RESTORED=$(json_field "$(printf '{"x":"%s"}' "$ESC")" 'sys.stdout.write(d["x"])')
[ "$RESTORED" = "$INPUT" ] \
  && pass "JE-4" "multi-line + tab round-trip" \
  || fail "JE-4" "round-trip" "expected: $INPUT, got: $RESTORED"

# Already-escaped sequences must NOT be double-decoded — `\n` (literal backslash+n)
# in input should round-trip back to literal backslash+n.
INPUT='shell escape \n stays literal'
ESC=$(json_escape "$INPUT")
RESTORED=$(json_field "$(printf '{"x":"%s"}' "$ESC")" 'sys.stdout.write(d["x"])')
[ "$RESTORED" = "$INPUT" ] \
  && pass "JE-5" "literal backslash-n preserved" \
  || fail "JE-5" "literal \\n round-trip" "expected: $INPUT, got: $RESTORED"

# Quotes inside content
INPUT='she said "hi" to him'
ESC=$(json_escape "$INPUT")
RESTORED=$(json_field "$(printf '{"x":"%s"}' "$ESC")" 'sys.stdout.write(d["x"])')
[ "$RESTORED" = "$INPUT" ] \
  && pass "JE-6" "embedded quotes round-trip" \
  || fail "JE-6" "quotes" "expected: $INPUT, got: $RESTORED"

# ── jp / jb: braces inside JSON string values ─────────────────────
echo
printf "${B}━━━ jp / jb ━━━${N}\n"

# Realistic Anthropic tool_use response with a grep pattern containing { and "
# (this is the exact shape that triggered commit 80fdf9f)
RESP='{"id":"msg_01","type":"message","role":"assistant","content":[{"type":"text","text":""},{"type":"tool_use","id":"toolu_X","name":"grep","input":{"pattern":"handle_cmd.*{\""}}],"stop_reason":"tool_use","usage":{"input_tokens":100,"output_tokens":50}}'

CB=$(jp "$RESP" content)
valid_json "$CB" \
  && pass "JS-1" "jp: content array with {-in-string" \
  || fail "JS-1" "jp content extraction" "got: $CB"

TU=$(jb "$RESP" tool_use)
valid_json "$TU" \
  && pass "JS-2" "jb: tool_use block with {-in-string" \
  || fail "JS-2" "jb tool_use" "got: $TU"

TN=$(jp "$TU" name)
[ "$TN" = "grep" ] \
  && pass "JS-3" "jp: nested name field" \
  || fail "JS-3" "tool name" "got: $TN"

TINP=$(jp "$TU" input)
valid_json "$TINP" \
  && pass "JS-4" "jp: nested object with brace-in-string" \
  || fail "JS-4" "input object" "got: $TINP"

PAT=$(jp "$TINP" pattern)
[ "$PAT" = 'handle_cmd.*{"' ] \
  && pass "JS-5" "jp: string field with literal { and \" decoded correctly" \
  || fail "JS-5" "pattern decode" "expected: handle_cmd.*{\", got: $PAT"

UNICODE=$(jp '{"x":"caf\u00e9 \u263a \ud83d\ude00 literal \\u00e9"}' x)
[ "$UNICODE" = $'caf\303\251 \342\230\272 \360\237\230\200 literal \\u00e9' ] \
  && pass "JS-5b" "jp: decodes JSON unicode escapes, preserves escaped backslash-u" \
  || fail "JS-5b" "unicode decode" "got: $UNICODE"


# ── parse_response on tool_use response with { in pattern ──────────
echo
printf "${B}━━━ parse_response ━━━${N}\n"

PROVIDER=anthropic
parse_response "$RESP"
[ "$TY" = "T" ]            && pass "PR-1" "type=tool_use detected"  || fail "PR-1" "TY=$TY"
[ "$TN" = "grep" ]          && pass "PR-2" "tool name extracted"     || fail "PR-2" "TN=$TN"
[ "$TI" = "toolu_X" ]       && pass "PR-3" "tool id extracted"       || fail "PR-3" "TI=$TI"
valid_json "$CB"            && pass "PR-4" "CB valid for append"     || fail "PR-4" "CB invalid" "$CB"

# Simulate the append step that previously broke: build the next MSGS.
# This matches the actual code at pu.sh:254 for the Anthropic CB branch.
MSGS_INIT='[{"role":"user","content":"go"}]'
TR_BLOCK='{"type":"tool_result","tool_use_id":"toolu_X","content":"some output"}'
NEW_MSGS=$(printf '%s' "$MSGS_INIT" | sed 's/]$//')",{\"role\":\"assistant\",\"content\":${CB}},{\"role\":\"user\",\"content\":[$TR_BLOCK]}]"
valid_json "$NEW_MSGS" \
  && pass "PR-5" "appended MSGS is valid JSON (regression for 80fdf9f)" \
  || fail "PR-5" "appended MSGS invalid" "first 200 chars: ${NEW_MSGS:0:200}"

# OpenAI Responses API: function calls are top-level output items with call_id.
ORESP='{"id":"resp_x","object":"response","output":[{"type":"reasoning","id":"rs_1","summary":[]},{"type":"function_call","id":"fc_1","call_id":"call_abc","name":"read","arguments":"{\"path\":\"pu.sh\"}","status":"completed"}],"usage":{"input_tokens":10,"output_tokens":5}}'
PROVIDER=openai
parse_response "$ORESP"
[ "$TY" = "T" ]             && pass "PR-6" "openai: function_call detected" || fail "PR-6" "TY=$TY"
[ "$TI" = "call_abc" ]      && pass "PR-7" "openai: call_id extracted" || fail "PR-7" "TI=$TI"
[ "$TN" = "read" ]          && pass "PR-8" "openai: function name extracted" || fail "PR-8" "TN=$TN"
[ "$TINP" = '{"path":"pu.sh"}' ] && pass "PR-9" "openai: escaped arguments decoded to JSON object" || fail "PR-9" "TINP=$TINP"
ORG=$(each_tool_use "$TC" '"reasoning"')
OTU=$(each_tool_use "$TC" '"function_call"')
OTI=$(jp "$OTU" call_id); OTN=$(jp "$OTU" name); OINP=$(jp "$OTU" arguments)
[ "$OTI/$OTN/$OINP" = 'call_abc/read/{"path":"pu.sh"}' ] \
  && pass "PR-10" "openai: each_tool_use anchors function_call object" \
  || fail "PR-10" "openai each_tool_use" "got: $OTI/$OTN/$OINP"
PRETTY_TC='[
  {
    "type": "function_call",
    "call_id": "call_pretty",
    "name": "read",
    "arguments": "{\"path\":\"pu.sh\"}"
  }
]'
PFLAT=$(printf '%s' "$PRETTY_TC" | tr -d '\n')
PTU=$(each_tool_use "$PFLAT" '"function_call"')
[ "$(jp "$PTU" call_id)/$(jp "$PTU" name)" = "call_pretty/read" ] \
  && pass "PR-11" "openai: pretty function_calls survive line compaction" \
  || fail "PR-11" "openai pretty function_calls" "got: $PTU"
parse_response '{"output_text":"direct final","usage":{"input_tokens":1,"output_tokens":1}}'
[ "$TY/$TX" = "X/direct final" ] \
  && pass "PR-12" "openai: top-level output_text string parsed" \
  || fail "PR-12" "openai top-level output_text" "TY=$TY TX=$TX"
OMSGS='[{"role":"user","content":"go"}]'
OTR=',{"type":"function_call_output","call_id":"call_abc","output":"ok"}'
ONEW=$(printf '%s' "$OMSGS" | sed 's/]$//')",${ORG},${OTU}${OTR}]"
valid_json "$ONEW" \
  && [ "$(json_field "$ONEW" 'sys.stdout.write(d[1]["type"]+":"+d[3]["call_id"])')" = "reasoning:call_abc" ] \
  && pass "PR-13" "openai: appended reasoning/function_call/function_call_output are schema-shaped" \
  || fail "PR-13" "openai append invalid" "got: $ONEW"

# OpenAI Responses uses max_output_tokens and supports reasoning.effort with tools.
curl(){ while [ $# -gt 0 ]; do [ "$1" = -d ] && { shift; printf '%s' "$1"; return; }; shift; done; }
PROVIDER=openai; MODEL=gpt-5.5; MAX_TOKENS=123; THINKING=; EFFORT=medium; EFFORT_OK=1
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert "max_output_tokens" in d and "max_tokens" not in d and "max_completion_tokens" not in d' \
  && pass "PR-14" "openai responses: request uses max_output_tokens" \
  || fail "PR-14" "openai token parameter" "request: $REQ"
json_field "$REQ" 'assert d["reasoning"]["effort"] == "medium" and "instructions" in d and d["tools"][0]["type"] == "function"' \
  && pass "PR-15" "openai responses: sends reasoning.effort with tools" \
  || fail "PR-15" "openai responses reasoning/tools" "request: $REQ"
PROVIDER=openai; MODEL=gpt-4o; MAX_TOKENS=123; THINKING=; EFFORT=high; EFFORT_OK=0
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert "reasoning" not in d and d["max_output_tokens"] == 123' \
  && pass "PR-16" "openai non-reasoning model: no effort/no token boost" \
  || fail "PR-16" "openai unsupported reasoning gated" "request: $REQ"
PROVIDER=openai; MODEL=gpt-5.5; MAX_TOKENS=123; THINKING=; EFFORT=none; EFFORT_OK=1
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert "reasoning" not in d' \
  && pass "PR-17" "openai effort=none suppresses reasoning field" \
  || fail "PR-17" "openai none reasoning" "request: $REQ"
PROVIDER=openai; MODEL=gpt-5.5; MAX_TOKENS=123; THINKING=; EFFORT=xhigh; EFFORT_OK=1
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert d["max_output_tokens"] == 32000' \
  && pass "PR-18" "openai xhigh gets larger output budget" \
  || fail "PR-18" "openai xhigh budget" "request: $REQ"
PROVIDER=anthropic; MODEL=claude-opus-4-7; EFFORT=xhigh; THINKING=; EFFORT_OK=1
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert d["effort"] == "xhigh" and d["thinking"]["type"] == "adaptive" and "budget_tokens" not in d["thinking"]' \
  && pass "PR-19" "anthropic: Opus 4.7 uses effort + adaptive thinking, not budget_tokens" \
  || fail "PR-19" "anthropic effort/adaptive" "request: $REQ"
unset -f curl
PROVIDER=anthropic

mkdir -p "$TMPD/home" "$TMPD/bin"
printf "OPENAI_API_KEY='saved-key'\nAGENT_PROVIDER='openai'\necho pwn > '$TMPD/pwn'\n" > "$TMPD/home/.pu.env"
cat > "$TMPD/bin/curl" <<'EOF'
#!/bin/sh
case " $* " in *"Authorization: Bearer saved-key"*) ;; *) printf '%s' '{"error":{"message":"missing saved key"}}'; exit 0;; esac
printf '%s' '{"output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":1,"output_tokens":1}}'
EOF
chmod +x "$TMPD/bin/curl"
OUT=$(HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" AGENT_MODEL=gpt-5.5 "$AGENT" -n hi 2>/dev/null); RC=$?
[ "$OUT" = ok ] && [ $RC -eq 0 ] && [ ! -e "$TMPD/pwn" ] \
  && pass "PR-20" "~/.pu.env safe parser loads key without executing shell" \
  || fail "PR-20" "saved key/env parser" "rc=$RC out=$OUT pwn=$([ -e "$TMPD/pwn" ] && echo yes || echo no)"

mkdir -p "$TMPD/emptyhome"; HOME="$TMPD/emptyhome"
printf '2\n export OPENAI_API_KEY="saved-key" \n\nnone\nY\n' | _setup 2>/dev/null
. "$TMPD/emptyhome/.pu.env"
[ "$OPENAI_API_KEY" = saved-key ] && [ "$(_clean_key ' OPENAI_API_KEY="saved-key" ')" = saved-key ] \
  && pass "PR-21" "login strips env/export-prefix/quotes/whitespace from pasted key" \
  || fail "PR-21" "key paste sanitization" "key=$OPENAI_API_KEY direct=$(_clean_key ' OPENAI_API_KEY="saved-key" ')"
HIST="$TMPD/hist.json"; HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" AGENT_MODEL=gpt-5.5 AGENT_HISTORY="$HIST" "$AGENT" -n hi >/dev/null 2>/dev/null
json_field "$(cat "$HIST")" 'assert d[-1]["role"] == "assistant" and d[-1]["content"] == "ok"' \
  && pass "PR-22" "final assistant response is saved to history" \
  || fail "PR-22" "assistant response missing from history" "hist=$(cat "$HIST")"

# ── trim_context end-to-end (mocked call_api) ──────────────────────
echo
printf "${B}━━━ trim_context ━━━${N}\n"

# Replace network-bound functions with deterministic stubs.
call_api(){ printf '%s' '{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"Earlier work: read pu.sh, ran 2 grep calls, found 1 issue."}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}'; }
info(){ :; }
err(){ printf '[err] %s\n' "$*" >&2; }
CTX_LIMIT=2000
AGENT_RESERVE=200

# Build a 7-message MSGS large enough to trigger compaction.
mkmsgs(){
  local pad=$1
  printf '[{"role":"user","content":"original task: find bugs"},'
  printf '{"role":"assistant","content":[{"type":"tool_use","id":"a","name":"read","input":{"path":"a.sh"}}]},'
  printf '{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"%s"}]},' "$pad"
  printf '{"role":"assistant","content":[{"type":"tool_use","id":"b","name":"read","input":{"path":"b.sh"}}]},'
  printf '{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"BBB"}]},'
  printf '{"role":"assistant","content":[{"type":"tool_use","id":"c","name":"read","input":{"path":"c.sh"}}]},'
  printf '{"role":"user","content":[{"type":"tool_result","tool_use_id":"c","content":"CCC"}]}]'
}
PADDING=$(printf 'x%.0s' $(seq 1 2500))
MSGS_BIG=$(mkmsgs "$PADDING")

NEW=$(trim_context "$MSGS_BIG")
valid_json "$NEW" \
  && pass "TC-1" "trim_context output is valid JSON" \
  || fail "TC-1" "trim_context output invalid" "len=${#NEW}, first 300: ${NEW:0:300}"

# Anchor (original task) preserved at index 0
ANCHOR=$(json_field "$NEW" 'sys.stdout.write(d[0]["content"])')
[ "$ANCHOR" = "original task: find bugs" ] \
  && pass "TC-2" "anchor (original task) preserved" \
  || fail "TC-2" "anchor lost" "got: $ANCHOR"

# Summary placeholder inserted at index 1
SUMMARY_CONTENT=$(json_field "$NEW" 'sys.stdout.write(d[1]["content"])')
case "$SUMMARY_CONTENT" in
  *"Earlier compacted"*) pass "TC-3" "summary placeholder inserted" ;;
  *)                     fail "TC-3" "summary missing" "got: $SUMMARY_CONTENT" ;;
esac

# Pairing invariant: every tool_use id has a matching tool_result tool_use_id
TUS=$(printf '%s' "$NEW" | grep -o '"id":"[a-z]"' | sort -u | sed 's/"id":/"tool_use_id":/g')
TRS=$(printf '%s' "$NEW" | grep -o '"tool_use_id":"[a-z]"' | sort -u)
[ "$TUS" = "$TRS" ] \
  && pass "TC-4" "tool_use ↔ tool_result pairing intact" \
  || fail "TC-4" "pairing broken" "uses: $TUS / results: $TRS"

# Compaction is a real shrink
[ "${#NEW}" -lt "${#MSGS_BIG}" ] \
  && pass "TC-5" "compacted MSGS is smaller (${#MSGS_BIG} → ${#NEW})" \
  || fail "TC-5" "no shrinkage" "${#MSGS_BIG} → ${#NEW}"

# Edge case: small MSGS (n<6) passes through unchanged
SHORT='[{"role":"user","content":"hi"},{"role":"assistant","content":"hello"}]'
OUT=$(trim_context "$SHORT")
[ "$OUT" = "$SHORT" ] \
  && pass "TC-6" "small MSGS (n<6) passes through unchanged" \
  || fail "TC-6" "n<6 mutated"

# Edge case: focus arg forces compaction even when under threshold
SHORT_BUT_OK='[{"role":"user","content":"task"},{"role":"assistant","content":[{"type":"tool_use","id":"a","name":"x","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"x"}]},{"role":"assistant","content":[{"type":"tool_use","id":"b","name":"x","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"y"}]},{"role":"assistant","content":[{"type":"tool_use","id":"c","name":"x","input":{}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"c","content":"z"}]}]'
OUT=$(trim_context "$SHORT_BUT_OK" "key files only")
[ "$OUT" != "$SHORT_BUT_OK" ] && valid_json "$OUT" \
  && pass "TC-7" "focus arg forces compaction (threshold bypass)" \
  || fail "TC-7" "focus didn't force"
OPENAI_BOUNDARY='[{"role":"user","content":"task"},{"role":"user","content":"old"},{"type":"reasoning","id":"rs_1","summary":[]},{"type":"function_call","call_id":"call_1","name":"read","arguments":"{}"},{"type":"function_call_output","call_id":"call_1","output":"ok"},{"role":"user","content":"next"},{"role":"assistant","content":"done"}]'
OUT=$(trim_context "$OPENAI_BOUNDARY" "force")
json_field "$OUT" 'types=[x.get("type") for x in d]; assert "function_call" not in types or types[types.index("function_call")-1] == "reasoning"' \
  && pass "TC-8" "trim_context keeps OpenAI reasoning before function_call" \
  || fail "TC-8" "openai reasoning/function_call boundary" "out=$OUT"
OLD_CTX=$CTX_LIMIT OLD_RES=$AGENT_RESERVE; CTX_LIMIT=20000; AGENT_RESERVE=1000
BIGRECENT=$(printf 'z%.0s' $(seq 1 6000))
RECENT_BIG='[{"role":"user","content":"task"},{"role":"assistant","content":"old1"},{"role":"user","content":"old2"},{"role":"assistant","content":"old3"},{"role":"user","content":"old4"},{"role":"assistant","content":"'"$BIGRECENT"'"},{"role":"user","content":"done"}]'
OUT=$(trim_context "$RECENT_BIG" "force")
valid_json "$OUT" && pass "TC-8b" "trim_context keeps retained large entries as valid JSON" || fail "TC-8b" "large retained entry made invalid JSON" "out=${OUT:0:200}"
OLD_KEEP=$AGENT_KEEP_RECENT; AGENT_KEEP_RECENT=100
BIGUNI=$(python3 -c 'print("é"*6000)')
UNIC_MSG='[{"role":"user","content":"task"},{"role":"assistant","content":"old1"},{"role":"user","content":"'"$BIGUNI"'"},{"role":"assistant","content":"old3"},{"role":"user","content":"old4"},{"role":"assistant","content":"old5"},{"role":"user","content":"done"}]'
REQF="$TMPD/compact_req.json"; call_api(){ printf '%s' "$1" > "$REQF"; printf '%s' '{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"summary"}]}'; }
OUT=$(trim_context "$UNIC_MSG" "force")
python3 -m json.tool "$REQF" >/dev/null 2>&1 && valid_json "$OUT" \
  && pass "TC-8c" "trim_context builds valid summary request for huge unicode entries" \
  || fail "TC-8c" "compaction summary request invalid" "req=$(head -c 200 "$REQF" 2>/dev/null) out=${OUT:0:120}"
PRETTY='[{"role":"user","content":"task"},{
  "role" : "assistant",
  "content" : "old pretty"
},{"role":"user","content":"old2"},{"role":"assistant","content":"old3"},{"role":"user","content":"old4"},{"role":"assistant","content":"old5"},{"role":"user","content":"done"}]'
OUT=$(trim_context "$PRETTY" "force")
valid_json "$OUT" && pass "TC-8d" "trim_context keeps pretty/multiline entries whole" || fail "TC-8d" "pretty entry compaction invalid" "out=$OUT"
SEP_PAYLOAD=$(awk 'BEGIN{for(i=0;i<120000;i++)printf "x},{y"}')
SEP_MSGS='[{"role":"user","content":"task"},{"role":"user","content":"old"},{"type":"reasoning","id":"rs_huge","summary":[]},{"type":"function_call","call_id":"call_huge","name":"grep","arguments":"{}"},{"type":"function_call_output","call_id":"call_huge","output":"'"$SEP_PAYLOAD"'"},{"role":"user","content":"latest"}]'
CTX_LIMIT=12000; AGENT_RESERVE=1000; AGENT_KEEP_RECENT=2000
OUT=$(trim_context "$SEP_MSGS" "huge separator payload")
valid_json "$OUT" && [ ${#OUT} -le $((CTX_LIMIT-AGENT_RESERVE)) ] && printf '%s' "$OUT" | grep -q 'omitted during compaction' \
  && pass "TC-8e" "huge tool output with literal },{ compacts quickly and validly" \
  || fail "TC-8e" "huge separator payload compaction invalid" "len=${#OUT} cap=$((CTX_LIMIT-AGENT_RESERVE)) out=${OUT:0:300}"
AGENT_KEEP_RECENT=$OLD_KEEP; CTX_LIMIT=$OLD_CTX; AGENT_RESERVE=$OLD_RES

# Edge case: API returns empty TX → local compaction note instead of passing through oversized MSGS
call_api(){ printf '%s' '{"error":{"message":"rate limit"}}'; }
OUT=$(trim_context "$MSGS_BIG" 2>/dev/null)
[ "$OUT" != "$MSGS_BIG" ] && valid_json "$OUT" && printf '%s' "$OUT" | grep -q 'compacted locally' \
  && pass "TC-9" "API failure → local compacted fallback" \
  || fail "TC-9" "local fallback didn't fire" "out=$OUT"

# New compaction guarantees: always valid and under CTX_LIMIT-AGENT_RESERVE.
OLD_CTX=$CTX_LIMIT OLD_RES=$AGENT_RESERVE OLD_KEEP=$AGENT_KEEP_RECENT
CTX_LIMIT=1400; AGENT_RESERVE=200; AGENT_KEEP_RECENT=100000
call_api(){ printf '%s' '{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"short structured summary"}]}'; }
OUT=$(trim_context "$MSGS_BIG" "hard budget")
valid_json "$OUT" && [ ${#OUT} -le $((CTX_LIMIT-AGENT_RESERVE)) ] \
  && pass "TC-9b" "normal compaction stays under hard budget" \
  || fail "TC-9b" "over budget or invalid" "len=${#OUT} cap=$((CTX_LIMIT-AGENT_RESERVE)) out=${OUT:0:200}"

HUGE_TASK=$(printf 'A%.0s' $(seq 1 5000))
HUGE_FIRST='[{"role":"user","content":"'"$HUGE_TASK"'"},{"role":"assistant","content":"old1"},{"role":"user","content":"old2"},{"role":"assistant","content":"old3"},{"role":"user","content":"old4"},{"role":"assistant","content":"old5"},{"role":"user","content":"latest"}]'
CTX_LIMIT=1200; AGENT_RESERVE=200; AGENT_KEEP_RECENT=500
call_api(){ printf '%s' '{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"summary"}]}'; }
OUT=$(trim_context "$HUGE_FIRST" "huge anchor")
valid_json "$OUT" && [ ${#OUT} -le $((CTX_LIMIT-AGENT_RESERVE)) ] \
  && pass "TC-9c" "huge first message falls back under budget" \
  || fail "TC-9c" "huge anchor escaped budget guard" "len=${#OUT} cap=$((CTX_LIMIT-AGENT_RESERVE)) out=${OUT:0:200}"

GIANT_SUM=$(printf 'S%.0s' $(seq 1 5000))
CTX_LIMIT=1500; AGENT_RESERVE=200; AGENT_KEEP_RECENT=500
call_api(){ printf '%s' '{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"'"$GIANT_SUM"'"}]}'; }
OUT=$(trim_context "$MSGS_BIG" "giant summary")
valid_json "$OUT" && [ ${#OUT} -le $((CTX_LIMIT-AGENT_RESERVE)) ] \
  && pass "TC-9d" "oversized model summary falls back under budget" \
  || fail "TC-9d" "giant summary escaped budget guard" "len=${#OUT} cap=$((CTX_LIMIT-AGENT_RESERVE)) out=${OUT:0:200}"

ERR_MSGS='[{"role":"user","content":"task"},{"role":"assistant","content":[{"type":"tool_use","id":"e","name":"read","input":{"path":"errfile.sh"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"e","content":"Error: file not found: errfile.sh"}]},{"role":"assistant","content":"old3"},{"role":"user","content":"old4"},{"role":"assistant","content":"old5"},{"role":"user","content":"latest"}]'
CTX_LIMIT=1800; AGENT_RESERVE=200; AGENT_KEEP_RECENT=100
call_api(){ printf '%s' '{"error":{"message":"rate limit"}}'; }
OUT=$(trim_context "$ERR_MSGS" "local facts" 2>/dev/null)
valid_json "$OUT" && printf '%s' "$OUT" | grep -q 'compacted locally' && printf '%s' "$OUT" | grep -q 'errfile.sh' && printf '%s' "$OUT" | grep -q 'Error:' \
  && pass "TC-9e" "local fallback preserves useful path/error facts" \
  || fail "TC-9e" "local fallback lost useful facts" "out=$OUT"

FIXTURE_MSGS=$(cat "$SCRIPT_DIR/fixtures/long_anthropic_msgs.json")
CTX_LIMIT=7000; AGENT_RESERVE=300; AGENT_KEEP_RECENT=200
call_api(){ printf '%s' '{"error":{"message":"rate limit"}}'; }
OUT=$(trim_context "$FIXTURE_MSGS" "fixture local fallback" 2>/dev/null)
valid_json "$FIXTURE_MSGS" && valid_json "$OUT" && [ ${#OUT} -le $((CTX_LIMIT-AGENT_RESERVE)) ] \
  && printf '%s' "$OUT" | grep -q 'pu.sh' \
  && printf '%s' "$OUT" | grep -q 'compaction-improvements.md' \
  && printf '%s' "$OUT" | grep -q 'eval/test_real.sh' \
  && printf '%s' "$OUT" | grep -q 'AGENT_KEEP_RECENT' \
  && printf '%s' "$OUT" | grep -q '\[exit:1\]' \
  && pass "TC-9f" "fixture compaction preserves realistic session facts" \
  || fail "TC-9f" "fixture compaction lost facts or budget" "len=${#OUT} cap=$((CTX_LIMIT-AGENT_RESERVE)) out=${OUT:0:500}"
CTX_LIMIT=$OLD_CTX; AGENT_RESERVE=$OLD_RES; AGENT_KEEP_RECENT=$OLD_KEEP

# End-to-end: a realistic oversized user-message history should compact before
# the model call, send valid JSON under budget, and continue/save normally.
OLD_CTX=$CTX_LIMIT OLD_RES=$AGENT_RESERVE OLD_KEEP=$AGENT_KEEP_RECENT OLD_HIST=${HISTORY:-} OLD_PIPE=$PIPE OLD_MAX=$MAX_STEPS OLD_PROVIDER=$PROVIDER OLD_MODEL=$MODEL OLD_EFFORT_OK=$EFFORT_OK OLD_KEY=${OPENAI_API_KEY:-}
USER_BLOW_MSGS=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",",":")))' "$SCRIPT_DIR/fixtures/long_user_msgs.json")
CTX_LIMIT=3400; AGENT_RESERVE=300; AGENT_KEEP_RECENT=1200
MSGS=$USER_BLOW_MSGS; HISTORY="$TMPD/user_blow_history.json"; LOG="$TMPD/user_blow.jsonl"; PIPE=1; MAX_STEPS=3; PROVIDER=openai; MODEL=gpt-5.5; EFFORT_OK=1; OPENAI_API_KEY=dummy
REQF="$TMPD/user_blow_request.json"; CALLS="$TMPD/user_blow_calls"; : > "$CALLS"
call_api(){
  printf x >> "$CALLS"
  case "$1" in
    *"Summarize the earlier transcript"*)
      printf '%s' '{"output_text":"Goal: debug pu.sh compaction with long user messages. Constraints: keep runtime dependency-free; preserve latest user request; validate JSON after compaction.","usage":{"input_tokens":1,"output_tokens":1}}';;
    *)
      printf '%s' "$1" > "$REQF"
      printf '%s' '{"output_text":"post compact ok","usage":{"input_tokens":1,"output_tokens":1}}';;
  esac
}
USER_BLOW_OUT=$(run_task "Now apply the smallest safe fix and report what changed" 2>"$TMPD/user_blow.err"); USER_BLOW_RC=$?
REQ_JSON=$(cat "$REQF" 2>/dev/null || true); HIST_JSON=$(cat "$HISTORY" 2>/dev/null || true); CALL_N=$(wc -c < "$CALLS" | tr -d ' ')
[ $USER_BLOW_RC -eq 0 ] && [ "$USER_BLOW_OUT" = "post compact ok" ] && [ "$CALL_N" = 2 ] \
  && valid_json "$REQ_JSON" && [ ${#REQ_JSON} -le $((CTX_LIMIT-AGENT_RESERVE)) ] \
  && json_field "$REQ_JSON" 'assert any("Earlier compacted" in (x.get("content","") if isinstance(x.get("content"), str) else "") for x in d); assert d[-1]["content"] == "Now apply the smallest safe fix and report what changed"' \
  && valid_json "$HIST_JSON" && json_field "$HIST_JSON" 'assert d[-1]["content"] == "post compact ok"' \
  && pass "TC-9g" "oversized realistic user history compacts and continues" \
  || fail "TC-9g" "user-message compaction did not continue cleanly" "rc=$USER_BLOW_RC calls=$CALL_N out=$USER_BLOW_OUT err=$(cat "$TMPD/user_blow.err" 2>/dev/null) req_len=${#REQ_JSON} req=${REQ_JSON:0:400}"

# Regression for an already-corrupted compacted OpenAI history: do not send a
# function_call_output unless the matching function_call is present before it.
ORPHAN_MSGS='[{"role":"user","content":"old task"},{"role":"user","content":"[Earlier compacted memory:\nok]"},{"role":"user","content":"continue"},{"type":"reasoning","id":"rs_orphan","summary":[]},{"type":"function_call_output","call_id":"call_ArSXATXNDlBnp0gPrS6lFTCZ","output":"Edited eval/test_real.sh"},{"type":"function_call","call_id":"call_good","name":"read","arguments":"{}"},{"type":"function_call_output","call_id":"call_good","output":"ok"}]'
CTX_LIMIT=20000; AGENT_RESERVE=1000; AGENT_KEEP_RECENT=1200
MSGS=$ORPHAN_MSGS; HISTORY="$TMPD/orphan_history.json"; LOG="$TMPD/orphan.jsonl"; PIPE=1; MAX_STEPS=2; PROVIDER=openai; MODEL=gpt-5.5; EFFORT_OK=1; OPENAI_API_KEY=dummy
REQF="$TMPD/orphan_request.json"
call_api(){ printf '%s' "$1" > "$REQF"; printf '%s' '{"output_text":"orphan clean ok","usage":{"input_tokens":1,"output_tokens":1}}'; }
ORPHAN_OUT=$(run_task "what bugs are outstanding?" 2>"$TMPD/orphan.err"); ORPHAN_RC=$?; ORPHAN_REQ=$(cat "$REQF" 2>/dev/null || true)
[ $ORPHAN_RC -eq 0 ] && [ "$ORPHAN_OUT" = "orphan clean ok" ] && valid_json "$ORPHAN_REQ" \
  && json_field "$ORPHAN_REQ" 'calls=set();
for x in d:
    if x.get("type") == "function_call": calls.add(x.get("call_id"))
    if x.get("type") == "function_call_output": assert x.get("call_id") in calls, x.get("call_id")
assert "call_ArSXATXNDlBnp0gPrS6lFTCZ" not in [x.get("call_id") for x in d if x.get("type") == "function_call_output"]' \
  && pass "TC-9h" "orphan OpenAI function_call_output is removed before request" \
  || fail "TC-9h" "orphan OpenAI output leaked into request" "rc=$ORPHAN_RC out=$ORPHAN_OUT err=$(cat "$TMPD/orphan.err" 2>/dev/null) req=$ORPHAN_REQ"
CTX_LIMIT=$OLD_CTX; AGENT_RESERVE=$OLD_RES; AGENT_KEEP_RECENT=$OLD_KEEP; HISTORY=$OLD_HIST; PIPE=$OLD_PIPE; MAX_STEPS=$OLD_MAX; PROVIDER=$OLD_PROVIDER; MODEL=$OLD_MODEL; EFFORT_OK=$OLD_EFFORT_OK; OPENAI_API_KEY=$OLD_KEY
call_api(){ printf '%s' '{"error":{"message":"rate limit"}}'; }

sleep(){ :; }
MSGS=; LOG="$TMPD/run_task.jsonl"; MAX_STEPS=1; PIPE=1; PROVIDER=openai; MODEL=gpt-5.5; EFFORT_OK=1
ERR=$(run_task "hi" 2>&1 >/dev/null); RC=$?
[ $RC -ne 0 ] && printf '%s' "$ERR" | grep -q 'API failed' && ! printf '%s' "$ERR" | grep -q 'Empty final' \
  && pass "TC-10" "run_task: API errors fail as API errors, not empty final" \
  || fail "TC-10" "API error misreported" "rc=$RC err=$ERR"
CNT="$TMPD/auth_count"; : > "$CNT"; call_api(){ echo x >> "$CNT"; printf '%s' '{"error":{"message":"Incorrect API key provided"}}'; }
ERR=$(run_task "hi" 2>&1 >/dev/null); RC=$?; CNT_N=$(wc -l < "$CNT" | tr -d ' ')
[ $RC -ne 0 ] && [ "$CNT_N" = 1 ] && printf '%s' "$ERR" | grep -q 'Incorrect API key' \
  && pass "TC-11" "run_task: auth errors are not retried" \
  || fail "TC-11" "auth error retry behavior" "rc=$RC calls=$CNT_N err=$ERR"
CNT="$TMPD/jsonerr_count"; : > "$CNT"; call_api(){ echo x >> "$CNT"; printf '%s' '{"error":{"message":"Invalid body: failed to parse JSON value"}}'; }
ERR=$(run_task "hi" 2>&1 >/dev/null); RC=$?; CNT_N=$(wc -l < "$CNT" | tr -d ' ')
[ $RC -ne 0 ] && [ "$CNT_N" = 1 ] && printf '%s' "$ERR" | grep -q 'Invalid body' \
  && pass "TC-11b" "run_task: invalid request JSON is not retried" \
  || fail "TC-11b" "invalid JSON retry behavior" "rc=$RC calls=$CNT_N err=$ERR"
CNT="$TMPD/transport_count"; : > "$CNT"; call_api(){ echo x >> "$CNT"; printf 'curl: (6) Could not resolve host\n'; return 6; }
ERR=$(run_task "hi" 2>&1 >/dev/null); RC=$?; CNT_N=$(wc -l < "$CNT" | tr -d ' ')
[ $RC -ne 0 ] && [ "$CNT_N" = 3 ] && printf '%s' "$ERR" | grep -q 'API transport' && ! printf '%s' "$ERR" | grep -q 'Empty final\|Max steps' \
  && pass "TC-12" "run_task: curl transport failures retry then report transport" \
  || fail "TC-12" "transport error masked" "rc=$RC calls=$CNT_N err=$ERR"
AFTER="$TMPD/after_empty"; MSGS=; call_api(){ printf ''; }
( run_task "hi" >/dev/null 2>/dev/null; r=$?; printf after > "$AFTER"; exit $r ); RC=$?
[ $RC -ne 0 ] && [ -f "$AFTER" ] \
  && pass "TC-12b" "run_task: empty API response returns instead of exiting shell" \
  || fail "TC-12b" "empty response exited caller" "rc=$RC after=$(test -f "$AFTER" && echo yes || echo no)"
MSGS=; AGENT_DEBUG_API="$TMPD/dbg"; call_api(){ printf '%s' '{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}'; }
run_task "hi" >/dev/null 2>/dev/null; unset AGENT_DEBUG_API
[ -s "$TMPD/dbg/input-1-0.json" ] && [ -s "$TMPD/dbg/resp-1-0.json" ] \
  && pass "TC-13" "run_task: AGENT_DEBUG_API captures input/response" \
  || fail "TC-13" "debug capture missing"
MSGS=; MAX_STEPS=1; call_api(){ printf '%s' '{"error":{"message":"model not found"}}'; }
ERR=$(run_task "hi" 2>&1 >/dev/null); RC=$?
[ $RC -ne 0 ] && printf '%s' "$ERR" | grep -q 'Try /model' \
  && pass "TC-14" "run_task: model errors suggest /model" \
  || fail "TC-14" "model hint missing" "err=$ERR"

# ── Tool truncation: line-aware + UTF-8 safe ───────────────────────
echo
printf "${B}━━━ tool truncation ━━━${N}\n"
AGENT_TOOL_TRUNC=2000

# Replicate the inline truncation snippet from pu.sh:206 for direct testing.
truncate_out(){ local out="$1" M
  M="${AGENT_TOOL_TRUNC:-2000}"
  [ ${#out} -gt "$M" ] && out="$(printf '%s\n' "$out" | awk '{a[NR]=$0}END{if(NR<=40){for(i=1;i<=NR;i++)print a[i];exit}for(i=1;i<=30;i++)print a[i];printf "...[%d lines truncated]...\n",NR-40;for(i=NR-9;i<=NR;i++)print a[i]}')"
  printf '%s' "$out"
}

OUT=$(truncate_out "small output stays intact")
[ "$OUT" = "small output stays intact" ] \
  && pass "TR-1" "short output passes through" \
  || fail "TR-1" "short output mutated"

LONG=$(seq 1 5000)
OUT=$(truncate_out "$LONG")
LINES=$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')
[ "$LINES" -le 41 ] \
  && pass "TR-2" "long output truncated to ≤41 lines (got $LINES)" \
  || fail "TR-2" "got $LINES lines"

[ "$(printf '%s\n' "$OUT" | head -1)" = "1" ] \
  && pass "TR-3" "first line preserved (file headers survive)" \
  || fail "TR-3" "first line lost"

[ "$(printf '%s\n' "$OUT" | tail -1)" = "5000" ] \
  && pass "TR-4" "last line preserved (errors at end survive)" \
  || fail "TR-4" "last line lost"

printf '%s\n' "$OUT" | grep -q "lines truncated" \
  && pass "TR-5" "truncation marker inserted" \
  || fail "TR-5" "no marker"

# UTF-8 multibyte content must not be split mid-character
UTF=$(seq 1 5000 | sed 's/$/ é/')
OUT=$(truncate_out "$UTF")
printf '%s' "$OUT" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null \
  && pass "TR-6" "UTF-8 multibyte preserved (no mid-char cut)" \
  || fail "TR-6" "UTF-8 corrupted"

# After truncation, the result must be safely embeddable in JSON via json_escape
ESC=$(json_escape "$OUT")
valid_json "$(printf '{"x":"%s"}' "$ESC")" \
  && pass "TR-7" "truncated output → json_escape → valid JSON" \
  || fail "TR-7" "truncated→escape produces invalid JSON"

# ── edit tool: multi-line oldText/newText (regression) ────────────
echo
printf "${B}━━━ edit tool ━━━${N}\n"

# Replicate the inline edit awk from pu.sh:196 for direct testing.
edit_replace(){ local file="$1" old="$2" new="$3"
  OLD="$old" NEW="$new" awk 'BEGIN{RS="\001";ORS="";o=ENVIRON["OLD"];n=ENVIRON["NEW"]}{i=index($0,o);while(i>0){printf "%s%s",substr($0,1,i-1),n;$0=substr($0,i+length(o));i=index($0,o)}printf "%s",$0}' "$file"
}

# ED-1: single-line edit
F=$(mktemp); printf 'foo\nbar\nbaz\n' > "$F"
OUT=$(edit_replace "$F" "bar" "BAR" 2>&1)
case "$OUT" in *"foo"*"BAR"*"baz"*) pass "ED-1" "single-line replacement" ;;
  *) fail "ED-1" "single-line" "got: $OUT" ;; esac

# ED-2: multi-line oldText (the regression — used to fail with awk: newline in string)
printf 'header\nline1\nline2\nline3\nfooter\n' > "$F"
ERR=$(edit_replace "$F" $'line1\nline2\nline3' "REPLACED" 2>&1 >/dev/null)
case "$ERR" in *"newline in string"*) fail "ED-2" "multi-line oldText: regression hit" "$ERR" ;;
  *) pass "ED-2" "multi-line oldText: no awk parse error" ;; esac

# ED-3: multi-line oldText AND newText round-trip
edit_replace "$F" $'line1\nline2\nline3' $'NEW1\nNEW2' 2>/dev/null > "$F.out"
EXPECTED=$'header\nNEW1\nNEW2\nfooter\n'
[ "$(cat "$F.out")" = "$(printf '%s' "$EXPECTED")" ] \
  && pass "ED-3" "multi-line old → multi-line new" \
  || fail "ED-3" "multi-line replacement" "got: $(cat "$F.out" | od -c | head -2)"
rm "$F.out"

# ED-4: oldText with special awk chars (&, \, regex metas)
printf 'use & here, and \\ too\n' > "$F"
OUT=$(edit_replace "$F" "& here, and \\" "REPLACED" 2>/dev/null)
case "$OUT" in *"REPLACED"*) pass "ED-4" "oldText with & and backslash" ;;
  *) fail "ED-4" "special chars" "got: $OUT" ;; esac

PIPE=1; CONFIRM=0
printf '%s\n' 'prefix' 'MSGS=; AGENT_DEBUG_API="$TMPD/dbg"; call_api(){ echo '\''{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}'\''; }' 'suffix' > "$F"
OLD_LINE='MSGS=; AGENT_DEBUG_API="$TMPD/dbg"; call_api(){ echo '\''{"output_text":"ok","usage":{"input_tokens":1,"output_tokens":1}}'\''; }'
OUT=$(run_tool edit "$(python3 -c 'import json,sys; print(json.dumps({"path":sys.argv[1],"oldText":sys.argv[2],"newText":"DEBUG_LINE"}, separators=(",",":")))' "$F" "$OLD_LINE")")
grep -q DEBUG_LINE "$F" && pass "ED-5" "edit matches exact oldText beyond first line" || fail "ED-5" "edit missed later exact oldText" "out=$OUT"
printf 'dup\ndup\n' > "$F"
OUT=$(run_tool edit "{\"path\":\"$F\",\"oldText\":\"dup\",\"newText\":\"X\"}")
case "$OUT" in *"matched multiple"*"larger unique"*) pass "ED-6" "edit tool rejects non-unique oldText with guidance" ;; *) fail "ED-6" "duplicate oldText not rejected" "got: $OUT" ;; esac
chmod 755 "$F"; printf 'one\n' > "$F"; run_tool edit "{\"path\":\"$F\",\"oldText\":\"one\",\"newText\":\"two\"}" >/dev/null
MODE=$(stat -f %Lp "$F" 2>/dev/null || stat -c %a "$F")
[ "$MODE" = 755 ] && pass "ED-7" "edit tool preserves executable mode" || fail "ED-7" "mode changed" "mode=$MODE"
OUT=$(run_tool edit "{\"path\":\"$F\",\"oldText\":\"missing\",\"newText\":\"X\"}")
printf '%s' "$OUT" | grep -q 'Read exact surrounding lines' && pass "ED-8" "edit not-found error gives retry guidance" || fail "ED-8" "edit guidance" "got=$OUT"
OUT=$(run_tool grep "{\"path\":\"$F\",\"pattern\":\"absent\"}")
[ "$OUT" = "No matches" ] && pass "ED-9" "grep no-match is explicit" || fail "ED-9" "grep no-match" "got: $OUT"
OUT=$(run_tool read "{\"path\":\"$F\",\"limit\":0}")
[ -z "$OUT" ] && pass "ED-10" "read limit:0 returns empty cleanly" || fail "ED-10" "read limit 0" "got: $OUT"
run_tool write "{\"path\":\"$F\",\"content\":\"a\\n\"}" >/dev/null
[ "$(wc -c < "$F" | tr -d ' ')" = 2 ] && pass "ED-11" "write preserves trailing newline" || fail "ED-11" "write newline stripped" "bytes=$(wc -c < "$F")"
printf 'a\nb\nc' > "$F"; run_tool edit "{\"path\":\"$F\",\"oldText\":\"b\\nc\",\"newText\":\"B\\nC\\n\"}" >/dev/null
[ "$(tail -c 1 "$F" | od -An -tx1 | tr -d ' ')" = 0a ] && pass "ED-12" "edit preserves trailing newline in newText" || fail "ED-12" "edit newline stripped" "od=$(od -An -tx1 "$F")"

# Harmony channel marker guard: blocks model CoT leakage from corrupting files.
printf 'before\nMARK\nafter\n' > "$F"
OUT=$(run_tool edit "{\"path\":\"$F\",\"oldText\":\"MARK\",\"newText\":\"X to=functions.edit leaked\"}")
printf '%s' "$OUT" | grep -q 'harmony channel markers' && grep -q MARK "$F" \
  && pass "ED-12a" "edit rejects newText with to=functions. marker; file unchanged" \
  || fail "ED-12a" "edit harmony guard (to=functions.)" "out=$OUT file=$(cat "$F")"
OUT=$(run_tool edit "{\"path\":\"$F\",\"oldText\":\"MARK\",\"newText\":\"X <|channel|>analysis leaked\"}")
printf '%s' "$OUT" | grep -q 'harmony channel markers' && grep -q MARK "$F" \
  && pass "ED-12b" "edit rejects newText with <|channel|> marker; file unchanged" \
  || fail "ED-12b" "edit harmony guard (<|channel|>)" "out=$OUT file=$(cat "$F")"
OUT=$(run_tool write "{\"path\":\"$F\",\"content\":\"x to=functions.read y\"}")
printf '%s' "$OUT" | grep -q 'harmony channel markers' && grep -q MARK "$F" \
  && pass "ED-12c" "write rejects content with to=functions. marker; file unchanged" \
  || fail "ED-12c" "write harmony guard" "out=$OUT file=$(cat "$F")"
run_tool edit "{\"path\":\"$F\",\"oldText\":\"MARK\",\"newText\":\"a function calls b\"}" >/dev/null
grep -q "a function calls b" "$F" \
  && pass "ED-12d" "edit guard does not false-trigger on benign 'function' text" \
  || fail "ED-12d" "edit guard false positive" "file=$(cat "$F")"
ERRF="$TMPD/spin.err"; spin_stop 2>"$ERRF"; [ ! -s "$ERRF" ] && pass "ED-13" "spin_stop is quiet on non-tty stderr" || fail "ED-13" "spinner leaked escapes" "bytes=$(wc -c < "$ERRF")"
mkdir -p "$TMPD/search/node_modules" "$TMPD/search/src"; printf match > "$TMPD/search/node_modules/a.txt"; printf match > "$TMPD/search/src/a.txt"
OUT=$(run_tool grep "{\"path\":\"$TMPD/search\",\"pattern\":\"match\"}" 2>"$TMPD/grep.err")
printf '%s' "$OUT" | grep -q 'src/a.txt' && ! printf '%s' "$OUT" | grep -q node_modules && ! grep -q 'Broken pipe' "$TMPD/grep.err" \
  && pass "ED-14" "grep excludes noisy directories without broken pipe noise" || fail "ED-14" "grep exclusions" "got=$OUT err=$(cat "$TMPD/grep.err")"
OUT=$(run_tool find "{\"path\":\"$TMPD/search\",\"name\":\"a.txt\"}")
printf '%s' "$OUT" | grep -q 'src/a.txt' && ! printf '%s' "$OUT" | grep -q node_modules \
  && pass "ED-15" "find prunes noisy directories" || fail "ED-15" "find exclusions" "got=$OUT"
PIPE=1; EFFORT=medium; handle_cmd '/effort xh' >/dev/null 2>/dev/null
[ "$EFFORT" = xhigh ] && pass "ED-16" "/effort changes effort interactively" || fail "ED-16" "/effort" "EFFORT=$EFFORT"
MSGS='[{"role":"user","content":"hi"}]'; HISTORY="$TMPD/flush_hist.json"; handle_cmd '/flush' >/dev/null 2>/dev/null
[ -z "$MSGS" ] && [ "$(cat "$HISTORY")" = '[]' ] \
  && pass "ED-17" "/flush clears conversation memory and history" || fail "ED-17" "/flush" "MSGS=$MSGS hist=$(cat "$HISTORY")"
MSGS=x; load >/dev/null 2>/dev/null; RC=$?
[ $RC -ne 0 ] && [ -z "$MSGS" ] && pass "ED-18" "empty [] history is not treated as resumed" || fail "ED-18" "empty history resume" "rc=$RC MSGS=$MSGS"
LOG="$TMPD/replay.jsonl"; printf '%s\n' '{"s":0,"t":"start","c":"old"}' '{"s":1,"t":"tool_call","c":"read: {\"path\":\"pu.sh\"}"}' '{"s":2,"t":"response","c":"done"}' > "$LOG"; INTERACTIVE=1
OUT=$(_replay 2>&1 >/dev/null)
printf '%s' "$OUT" | grep -q '>.*old' && printf '%s' "$OUT" | grep -q 'read:' && printf '%s' "$OUT" | grep -q done \
  && pass "ED-19" "resume replay shows last messages" || fail "ED-19" "replay" "out=$OUT"

rm "$F"

# ── Real-world-ish workflows (mocked APIs, real tools/CLI) ─────────
echo
printf "${B}━━━ real-world workflows ━━━${N}\n"

# Full CLI startup with fake curl: loads AGENTS.md into
# the actual API request payload.
cat > "$TMPD/bin/curl" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  if [ "$1" = -d ]; then shift; printf '%s' "$1" > "${PU_CAPTURE:?}"; fi
  shift
done
printf '%s' '{"output_text":"cli ok","usage":{"input_tokens":1,"output_tokens":1}}'
EOF
chmod +x "$TMPD/bin/curl"
CLI_PROJ="$TMPD/cli project"; mkdir -p "$CLI_PROJ"
printf 'Project rule: always mention ACME-42.\n' > "$CLI_PROJ/AGENTS.md"
printf 'incident id: INC-123\nroot cause: cache stampede\n' > "$CLI_PROJ/input.md"
CAP="$TMPD/cli_payload.json"
CLI_OUT=$(cd "$CLI_PROJ" && PATH="$TMPD/bin:$PATH" PU_CAPTURE="$CAP" OPENAI_API_KEY=dummy AGENT_PROVIDER=openai AGENT_MODEL=gpt-4o AGENT_LOG="$TMPD/cli.jsonl" "$AGENT" -n 'Summarize input.md for the changelog' 2>/dev/null); CLI_RC=$?
[ $CLI_RC -eq 0 ] && [ "$CLI_OUT" = "cli ok" ] && [ -s "$CLI_PROJ/.pu-history.json" ] && json_field "$(cat "$CAP")" 'assert "Project rule: always mention ACME-42" in d["instructions"] and d["input"][0]["content"] == "Summarize input.md for the changelog"' \
  && pass "RW-1" "CLI loads context and writes default history" \
  || fail "RW-1" "CLI context/history integration" "rc=$CLI_RC out=$CLI_OUT payload=$(cat "$CAP" 2>/dev/null)"

CAP="$TMPD/pipe_payload.json"
printf 'stdin review notes\n' | (cd "$CLI_PROJ" && PATH="$TMPD/bin:$PATH" PU_CAPTURE="$CAP" OPENAI_API_KEY=dummy AGENT_PROVIDER=openai AGENT_MODEL=gpt-4o "$AGENT" --pipe 'plus suffix' >/dev/null 2>"$TMPD/pipe.err"); CLI_RC=$?
[ $CLI_RC -eq 0 ] && json_field "$(cat "$CAP")" 'assert d["input"][1]["content"] == "cli ok"; c=d["input"][-1]["content"]; assert "stdin review notes" in c and "plus suffix" in c' \
  && pass "RW-2" "--pipe resumes default history and combines stdin with task suffix" \
  || fail "RW-2" "pipe task composition/resume" "rc=$CLI_RC err=$(cat "$TMPD/pipe.err") payload=$(cat "$CAP" 2>/dev/null)"

# Anthropic-style multi-step workflow: model asks to write a file with a
# realistic path/content, reads it back, then returns a final answer.
RW_DIR="$TMPD/rw project"; mkdir -p "$RW_DIR"; OLD_PWD=$(pwd); cd "$RW_DIR" || exit 1
PIPE=1; CONFIRM=0; MSGS=; HISTORY=; LOG="$TMPD/rw_anthropic.jsonl"; MAX_STEPS=5
PROVIDER=anthropic; MODEL=claude-opus-4-7; ANTHROPIC_API_KEY=dummy; EFFORT_OK=1; TOKEN_IN=0; TOKEN_OUT=0; COST_USD=0
RW_COUNT="$TMPD/rw_anth.count"; printf 0 > "$RW_COUNT"
call_api(){ RW_N=$(( $(cat "$RW_COUNT") + 1 )); printf '%s' "$RW_N" > "$RW_COUNT"; case "$RW_N" in
  1) printf '%s' '{"content":[{"type":"text","text":"I will create the note."},{"type":"tool_use","id":"toolu_write","name":"write","input":{"path":"notes/plan \u00fc.txt","content":"alpha\nbeta \"quoted\"\n"}}],"usage":{"input_tokens":10,"output_tokens":5}}' ;;
  2) printf '%s' '{"content":[{"type":"tool_use","id":"toolu_read","name":"read","input":{"path":"notes/plan \u00fc.txt","offset":1,"limit":5}}],"usage":{"input_tokens":10,"output_tokens":5}}' ;;
  *) printf '%s' '{"content":[{"type":"text","text":"Created and verified notes/plan \u00fc.txt."}],"usage":{"input_tokens":10,"output_tokens":5}}' ;;
 esac; }
RW_OUT=$(run_task "Create and verify a release note" 2>"$TMPD/rw_anth.err"); RW_RC=$?
cd "$OLD_PWD" || exit 1
[ $RW_RC -eq 0 ] && [ "$(cat "$RW_DIR/notes/plan ü.txt" 2>/dev/null)" = $'alpha\nbeta "quoted"' ] \
  && pass "RW-3" "anthropic workflow writes realistic file path/content" \
  || fail "RW-3" "anthropic write/read workflow" "rc=$RW_RC out=$RW_OUT err=$(cat "$TMPD/rw_anth.err")"
printf '%s' "$RW_OUT" | grep -q 'Created and verified' \
  && pass "RW-4" "anthropic workflow surfaces final answer" \
  || fail "RW-4" "anthropic final output" "out=$RW_OUT"
TCALLS=$(grep -c '"t":"tool_call"' "$TMPD/rw_anthropic.jsonl" 2>/dev/null || echo 0)
[ "$TCALLS" -ge 2 ] \
  && pass "RW-5" "anthropic workflow logs multiple tool calls" \
  || fail "RW-5" "anthropic tool logging" "calls=$TCALLS log=$(cat "$TMPD/rw_anthropic.jsonl" 2>/dev/null)"

# OpenAI Responses-style workflow: function_call items are looped back alongside
# function_call_output, with a checkpoint history file saved at the end.
RW_DIR2="$TMPD/rw openai"; mkdir -p "$RW_DIR2"; OLD_PWD=$(pwd); cd "$RW_DIR2" || exit 1
PIPE=1; CONFIRM=0; MSGS=; HISTORY="$TMPD/rw_openai_history.json"; LOG="$TMPD/rw_openai.jsonl"; MAX_STEPS=5
PROVIDER=openai; MODEL=gpt-5.5; EFFORT=none; EFFORT_OK=1; TOKEN_IN=0; TOKEN_OUT=0; COST_USD=0
RW_COUNT="$TMPD/rw_openai.count"; printf 0 > "$RW_COUNT"
call_api(){ RW_N=$(( $(cat "$RW_COUNT") + 1 )); printf '%s' "$RW_N" > "$RW_COUNT"; case "$RW_N" in
  1) printf '%s' '{"output":[{"type":"reasoning","id":"rs_1","summary":[]},{"type":"function_call","id":"fc_1","call_id":"call_write","name":"write","arguments":"{\"path\":\"src/app.txt\",\"content\":\"hello from openai\nbrace { ok }\n\"}","status":"completed"}],"usage":{"input_tokens":10,"output_tokens":5}}' ;;
  2) printf '%s' '{"output":[{"type":"function_call","id":"fc_2","call_id":"call_read","name":"read","arguments":"{\"path\":\"src/app.txt\"}","status":"completed"}],"usage":{"input_tokens":10,"output_tokens":5}}' ;;
  *) printf '%s' '{"output_text":"OpenAI workflow done.","usage":{"input_tokens":10,"output_tokens":5}}' ;;
 esac; }
RW_OUT=$(run_task "Create and verify app artifact" 2>"$TMPD/rw_openai.err"); RW_RC=$?
cd "$OLD_PWD" || exit 1
EXPECTED_OPENAI=$'hello from openai\nbrace { ok }'
[ $RW_RC -eq 0 ] && [ "$(cat "$RW_DIR2/src/app.txt" 2>/dev/null)" = "$EXPECTED_OPENAI" ] \
  && pass "RW-6" "openai workflow writes multiline quoted content" \
  || fail "RW-6" "openai write/read workflow" "rc=$RW_RC out=$RW_OUT err=$(cat "$TMPD/rw_openai.err") file=$(cat "$RW_DIR2/src/app.txt" 2>/dev/null)"
printf '%s' "$RW_OUT" | grep -q 'OpenAI workflow done' \
  && pass "RW-7" "openai workflow surfaces final answer" \
  || fail "RW-7" "openai final output" "out=$RW_OUT"
valid_json "$(cat "$HISTORY")" && json_field "$(cat "$HISTORY")" 'assert d[-1]["role"] == "assistant" and d[-1]["content"] == "OpenAI workflow done."' \
  && pass "RW-8" "openai workflow saves valid checkpoint history" \
  || fail "RW-8" "openai checkpoint history" "hist=$(cat "$HISTORY" 2>/dev/null)"

# Tool behavior that resembles common repo work: large files require ranged
# reads, and failing shell commands preserve the exit code in tool output.
PIPE=1; CONFIRM=0; AGENT_READ_MAX=20
BIG="$TMPD/big.log"; printf 'line 1\nline 2\nline 3\nline 4\n' > "$BIG"
OUT=$(run_tool read "{\"path\":\"$BIG\"}")
printf '%s' "$OUT" | grep -q 'pass offset/limit' \
  && pass "RW-9" "read refuses oversized file without range" \
  || fail "RW-9" "large read guard" "out=$OUT"
OUT=$(run_tool read "{\"path\":\"$BIG\",\"offset\":2,\"limit\":2}")
[ "$OUT" = $'line 2\nline 3' ] \
  && pass "RW-10" "read offset/limit returns requested range" \
  || fail "RW-10" "range read" "out=$OUT"
OUT=$(run_tool bash '{"command":"printf before; exit 7"}')
printf '%s' "$OUT" | grep -q '\[exit:7\]' \
  && pass "RW-11" "bash tool includes nonzero exit code" \
  || fail "RW-11" "bash exit status" "out=$OUT"

# ── Summary ────────────────────────────────────────────────────────
echo
printf "${B}━━━ RESULTS ━━━${N}\n"
printf "${G}PASS: $PASS${N}  ${R}FAIL: $FAIL${N}  TOTAL: $TOTAL\n"
[ $FAIL -eq 0 ] && exit 0 || exit 1
