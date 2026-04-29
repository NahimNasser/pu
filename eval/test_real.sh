#!/bin/bash
# Behavioral tests for pu.sh — sources the actual functions and validates
# real outputs against Python's json parser. Catches what grep-based tests miss.
#
# Regression coverage:
#   - json_escape control-char handling   (commit 65f6728)
#   - jp/jb/j1st brace-in-string handling (commit 80fdf9f)
#   - trim_context end-to-end correctness (commit 6adc939)
set -u
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT="$SCRIPT_DIR/../pu.sh"
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
set +u

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

# ── jp / jb / j1st: braces inside JSON string values ───────────────
echo
printf "${B}━━━ jp / jb / j1st ━━━${N}\n"

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

# j1st: first object in an array where strings contain brackets
ARR='[{"path":"a/[1]"},{"path":"b/{2}"}]'
F1=$(j1st "$ARR")
valid_json "$F1" \
  && [ "$(jp "$F1" path)" = "a/[1]" ] \
  && pass "JS-6" "j1st: first object with [-in-string" \
  || fail "JS-6" "j1st" "got: $F1"

# Pre-fix regression: a brace in a string used to truncate or over-extend
# extraction. Verify j1st on an object whose string has both { and }.
WEIRD='{"role":"user","content":"text { with } braces"}'
GOT=$(j1st "$WEIRD")
[ "$GOT" = "$WEIRD" ] \
  && pass "JS-7" "j1st: paired braces in string don't fool walker" \
  || fail "JS-7" "j1st paired braces" "expected: $WEIRD, got: $GOT"

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
OMSGS='[{"role":"user","content":"go"}]'
OTR=',{"type":"function_call_output","call_id":"call_abc","output":"ok"}'
ONEW=$(printf '%s' "$OMSGS" | sed 's/]$//')",${ORG},${OTU}${OTR}]"
valid_json "$ONEW" \
  && [ "$(json_field "$ONEW" 'sys.stdout.write(d[1]["type"]+":"+d[3]["call_id"])')" = "reasoning:call_abc" ] \
  && pass "PR-12" "openai: appended reasoning/function_call/function_call_output are schema-shaped" \
  || fail "PR-12" "openai append invalid" "got: $ONEW"

# OpenAI Responses uses max_output_tokens and supports reasoning.effort with tools.
curl(){ while [ $# -gt 0 ]; do [ "$1" = -d ] && { shift; printf '%s' "$1"; return; }; shift; done; }
PROVIDER=openai; MODEL=gpt-5.5; MAX_TOKENS=123; THINKING=; EFFORT=medium; EFFORT_OK=1
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert "max_output_tokens" in d and "max_tokens" not in d and "max_completion_tokens" not in d' \
  && pass "PR-13" "openai responses: request uses max_output_tokens" \
  || fail "PR-13" "openai token parameter" "request: $REQ"
json_field "$REQ" 'assert d["reasoning"]["effort"] == "medium" and "instructions" in d and d["tools"][0]["type"] == "function"' \
  && pass "PR-14" "openai responses: sends reasoning.effort with tools" \
  || fail "PR-14" "openai responses reasoning/tools" "request: $REQ"
PROVIDER=openai; MODEL=gpt-4o; MAX_TOKENS=123; THINKING=; EFFORT=high; EFFORT_OK=0
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert "reasoning" not in d and d["max_output_tokens"] == 123' \
  && pass "PR-15" "openai non-reasoning model: no effort/no token boost" \
  || fail "PR-15" "openai unsupported reasoning gated" "request: $REQ"
PROVIDER=openai; MODEL=gpt-5.5; MAX_TOKENS=123; THINKING=; EFFORT=none; EFFORT_OK=1
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert "reasoning" not in d' \
  && pass "PR-16" "openai effort=none suppresses reasoning field" \
  || fail "PR-16" "openai none reasoning" "request: $REQ"
PROVIDER=openai; MODEL=gpt-5.5; MAX_TOKENS=123; THINKING=; EFFORT=xhigh; EFFORT_OK=1
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert d["max_output_tokens"] == 32000' \
  && pass "PR-17" "openai xhigh gets larger output budget" \
  || fail "PR-17" "openai xhigh budget" "request: $REQ"
PROVIDER=anthropic; MODEL=claude-opus-4-7; EFFORT=xhigh; THINKING=; EFFORT_OK=1
REQ=$(call_api '[{"role":"user","content":"hi"}]')
json_field "$REQ" 'assert d["effort"] == "xhigh" and d["thinking"]["type"] == "adaptive" and "budget_tokens" not in d["thinking"]' \
  && pass "PR-18" "anthropic: Opus 4.7 uses effort + adaptive thinking, not budget_tokens" \
  || fail "PR-18" "anthropic effort/adaptive" "request: $REQ"
unset -f curl
PROVIDER=anthropic

mkdir -p "$TMPD/home" "$TMPD/bin"
printf "OPENAI_API_KEY='saved-key'\nAGENT_PROVIDER='openai'\n" > "$TMPD/home/.pu.env"
cat > "$TMPD/bin/curl" <<'EOF'
#!/bin/sh
case " $* " in *"Authorization: Bearer saved-key"*) ;; *) printf '%s' '{"error":{"message":"missing saved key"}}'; exit 0;; esac
printf '%s' '{"output":[{"type":"message","content":[{"type":"output_text","text":"ok"}]}],"usage":{"input_tokens":1,"output_tokens":1}}'
EOF
chmod +x "$TMPD/bin/curl"
OUT=$(HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" AGENT_MODEL=gpt-5.5 "$AGENT" -n hi 2>/dev/null); RC=$?
[ "$OUT" = ok ] && [ $RC -eq 0 ] \
  && pass "PR-19" "~/.pu.env key loads with AGENT_MODEL and exits 0" \
  || fail "PR-19" "saved key/noninteractive exit" "rc=$RC out=$OUT"

mkdir -p "$TMPD/emptyhome"; HOME="$TMPD/emptyhome"
printf '2\n  OPENAI_API_KEY="saved-key" \n\nnone\nY\n' | _setup 2>/dev/null
. "$TMPD/emptyhome/.pu.env"
[ "$OPENAI_API_KEY" = saved-key ] \
  && pass "PR-20" "login strips env-prefix/quotes/whitespace from pasted key" \
  || fail "PR-20" "key paste sanitization" "key=$OPENAI_API_KEY"
HIST="$TMPD/hist.json"; HOME="$TMPD/home" PATH="$TMPD/bin:$PATH" AGENT_MODEL=gpt-5.5 AGENT_HISTORY="$HIST" "$AGENT" -n hi >/dev/null 2>/dev/null
json_field "$(cat "$HIST")" 'assert d[-1]["role"] == "assistant" and d[-1]["content"] == "ok"' \
  && pass "PR-21" "final assistant response is saved to history" \
  || fail "PR-21" "assistant response missing from history" "hist=$(cat "$HIST")"

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

# Edge case: API returns empty TX → fallback to original
call_api(){ printf '%s' '{"error":{"message":"rate limit"}}'; }
OUT=$(trim_context "$MSGS_BIG" 2>/dev/null)
[ "$OUT" = "$MSGS_BIG" ] \
  && pass "TC-8" "API failure → safe fallback to original MSGS" \
  || fail "TC-8" "fallback didn't fire"

sleep(){ :; }
MSGS=; LOG="$TMPD/run_task.jsonl"; MAX_STEPS=1; PIPE=1; PROVIDER=openai; MODEL=gpt-5.5; EFFORT_OK=1
ERR=$(run_task "hi" 2>&1 >/dev/null); RC=$?
[ $RC -ne 0 ] && printf '%s' "$ERR" | grep -q 'API failed' && ! printf '%s' "$ERR" | grep -q 'Empty final' \
  && pass "TC-9" "run_task: API errors fail as API errors, not empty final" \
  || fail "TC-9" "API error misreported" "rc=$RC err=$ERR"
CNT="$TMPD/auth_count"; : > "$CNT"; call_api(){ echo x >> "$CNT"; printf '%s' '{"error":{"message":"Incorrect API key provided"}}'; }
ERR=$(run_task "hi" 2>&1 >/dev/null); RC=$?; CNT_N=$(wc -l < "$CNT" | tr -d ' ')
[ $RC -ne 0 ] && [ "$CNT_N" = 1 ] && printf '%s' "$ERR" | grep -q 'Incorrect API key' \
  && pass "TC-10" "run_task: auth errors are not retried" \
  || fail "TC-10" "auth error retry behavior" "rc=$RC calls=$CNT_N err=$ERR"

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
  OLD="$old" NEW="$new" awk 'BEGIN{RS="\0";ORS="";o=ENVIRON["OLD"];n=ENVIRON["NEW"]}{i=index($0,o);while(i>0){printf "%s%s",substr($0,1,i-1),n;$0=substr($0,i+length(o));i=index($0,o)}printf "%s",$0}' "$file"
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
printf 'dup\ndup\n' > "$F"
OUT=$(run_tool edit "{\"path\":\"$F\",\"oldText\":\"dup\",\"newText\":\"X\"}")
case "$OUT" in *"matched multiple"*) pass "ED-5" "edit tool rejects non-unique oldText" ;; *) fail "ED-5" "duplicate oldText not rejected" "got: $OUT" ;; esac
chmod 755 "$F"; printf 'one\n' > "$F"; run_tool edit "{\"path\":\"$F\",\"oldText\":\"one\",\"newText\":\"two\"}" >/dev/null
MODE=$(stat -f %Lp "$F" 2>/dev/null || stat -c %a "$F")
[ "$MODE" = 755 ] && pass "ED-6" "edit tool preserves executable mode" || fail "ED-6" "mode changed" "mode=$MODE"
OUT=$(run_tool grep "{\"path\":\"$F\",\"pattern\":\"absent\"}")
[ "$OUT" = "No matches" ] && pass "ED-7" "grep no-match is explicit" || fail "ED-7" "grep no-match" "got: $OUT"
OUT=$(run_tool read "{\"path\":\"$F\",\"limit\":0}")
[ -z "$OUT" ] && pass "ED-8" "read limit:0 returns empty cleanly" || fail "ED-8" "read limit 0" "got: $OUT"
run_tool write "{\"path\":\"$F\",\"content\":\"a\\n\"}" >/dev/null
[ "$(wc -c < "$F" | tr -d ' ')" = 2 ] && pass "ED-9" "write preserves trailing newline" || fail "ED-9" "write newline stripped" "bytes=$(wc -c < "$F")"
printf 'a\nb\nc' > "$F"; run_tool edit "{\"path\":\"$F\",\"oldText\":\"b\\nc\",\"newText\":\"B\\nC\\n\"}" >/dev/null
[ "$(tail -c 1 "$F" | od -An -tx1 | tr -d ' ')" = 0a ] && pass "ED-10" "edit preserves trailing newline in newText" || fail "ED-10" "edit newline stripped" "od=$(od -An -tx1 "$F")"
ERRF="$TMPD/spin.err"; spin_stop 2>"$ERRF"; [ ! -s "$ERRF" ] && pass "ED-11" "spin_stop is quiet on non-tty stderr" || fail "ED-11" "spinner leaked escapes" "bytes=$(wc -c < "$ERRF")"

rm "$F"

# ── Summary ────────────────────────────────────────────────────────
echo
printf "${B}━━━ RESULTS ━━━${N}\n"
printf "${G}PASS: $PASS${N}  ${R}FAIL: $FAIL${N}  TOTAL: $TOTAL\n"
[ $FAIL -eq 0 ] && exit 0 || exit 1
