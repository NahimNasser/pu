#!/bin/bash
# ══════════════════════════════════════════════════════════════
# Full coverage matrix — tests BOTH what pu.sh has AND lacks
# Honest comparison against Pi's feature set
# ══════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENT="$SCRIPT_DIR/../pu.sh"
HAS=0 MISSING=0 PARTIAL=0 TOTAL=0

G='\033[32m' R='\033[31m' Y='\033[33m' B='\033[36m' D='\033[90m' N='\033[0m'

has()     { HAS=$((HAS+1));     TOTAL=$((TOTAL+1)); printf "${G}✅${N} %-45s %s\n" "$1" "$2"; }
missing() { MISSING=$((MISSING+1)); TOTAL=$((TOTAL+1)); printf "${R}❌${N} %-45s %s\n" "$1" "$2"; }
partial() { PARTIAL=$((PARTIAL+1)); TOTAL=$((TOTAL+1)); printf "${Y}⚠️${N}  %-45s %s\n" "$1" "$2"; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT
cp "$AGENT" "$TMPD/pu.sh"
chmod +x "$TMPD/pu.sh"
cd "$TMPD"

echo ""
printf "${B}══════════════════════════════════════════════════════${N}\n"
printf "${B}  FULL CAPABILITY COVERAGE: pu.sh vs Pi features  ${N}\n"
printf "${B}══════════════════════════════════════════════════════${N}\n"

# ── 1. TOOLS ──
echo ""
printf "${B}─── Tools ───${N}\n"

grep -q 'sh -c\|bash -c' pu.sh \
  && has "Shell command execution" "sh -c" \
  || missing "Shell command execution" ""

# Does it have a dedicated read tool?
grep -q '"read"\|"name":"read"' pu.sh \
  && has "File read tool (native)" "" \
  || missing "File read tool (native)" "Pi: read with offset/limit/images"

# Dedicated write tool?
grep -q '"write"\|"name":"write"' pu.sh \
  && has "File write tool (native)" "" \
  || missing "File write tool (native)" "Pi: write creates dirs"

# Surgical edit tool?
grep -q '"edit"\|exact.*replacement\|oldText.*newText' pu.sh \
  && has "Surgical file edit tool" "" \
  || missing "Surgical file edit tool" "Pi: edit with exact text match"

# Multiple tools registered?
TOOL_COUNT=$(grep -o '"name":"[^"]*"' pu.sh | sort -u | wc -l | tr -d ' ')
[ "$TOOL_COUNT" -gt 1 ] \
  && has "Multiple named tools ($TOOL_COUNT)" "" \
  || missing "Multiple named tools" "Pi: 7 built-in (read/write/edit/bash/grep/find/ls)"

# Grep/find/ls tools?
grep -q '"grep"\|"find"\|"ls"' pu.sh \
  && has "Search tools (grep/find/ls)" "" \
  || missing "Search tools (grep/find/ls)" "Pi: dedicated grep/find/ls tools"

# ── 2. CONVERSATION ──
echo ""
printf "${B}─── Conversation ───${N}\n"

grep -q 'messages\|history\|conversation\|MS=' pu.sh \
  && has "Multi-turn conversation" "" \
  || missing "Multi-turn conversation" ""

# Streaming
grep -q 'stream' pu.sh \
  && partial "Streaming responses" "flag exists but no SSE parsing" \
  || missing "Streaming responses" "Pi: token-by-token SSE/WebSocket"

# Multi-shot / steering
grep -q 'steer\|follow.up\|queue\|multi.shot' pu.sh \
  && has "Multi-shot / steering mid-turn" "" \
  || missing "Multi-shot / steering mid-turn" "Pi: Enter=steer, Alt+Enter=follow-up"

# Thinking levels
grep -q 'thinking\|reasoning.*level\|budget_tokens' pu.sh \
  && has "Thinking/reasoning levels" "" \
  || missing "Thinking/reasoning levels" "Pi: off/minimal/low/medium/high/xhigh"

# Image input
grep -q 'image\|png\|jpg\|base64.*image' pu.sh \
  && has "Image input support" "" \
  || missing "Image input support" "Pi: paste/drag/file reference"

# File references (@file)
grep -q '@.*file\|file.*reference\|fuzzy' pu.sh \
  && has "File references (@file)" "" \
  || missing "File references (@file)" "Pi: @file fuzzy search"

# ── 3. SESSION ──
echo ""
printf "${B}─── Session Management ───${N}\n"

grep -q 'checkpoint\|resume\|HISTORY\|save.*state\|load.*state\|HI=' pu.sh \
  && partial "Session persistence" "single checkpoint file" \
  || missing "Session persistence" "Pi: JSONL tree with branching"

grep -q 'branch\|tree\|parentId\|fork' pu.sh \
  && has "Session branching / tree" "" \
  || missing "Session branching / tree" "Pi: /tree navigate any point"

grep -q 'fork\|/fork' pu.sh \
  && has "Session forking" "" \
  || missing "Session forking" "Pi: /fork creates new session from any point"

grep -q 'compact.*summar\|LLM.*summar\|smart.*compact' pu.sh \
  && has "Smart compaction (LLM summary)" "" \
  || { grep -q 'truncat\|context.*limit\|cw()' pu.sh \
    && partial "Context management" "dumb truncation, not LLM summary" \
    || missing "Context management" "Pi: auto/manual LLM compaction"; }

grep -q 'export.*html\|share.*gist\|/export\|/share' pu.sh \
  && has "Session export / sharing" "" \
  || missing "Session export / sharing" "Pi: /export HTML, /share gist"

# ── 4. EXTENSIBILITY ──
echo ""
printf "${B}─── Extensibility ───${N}\n"

grep -q 'registerTool\|custom.*tool\|plugin\|extension' pu.sh \
  && has "Custom tool registration" "" \
  || missing "Custom tool registration" "Pi: pi.registerTool() TypeScript API"

grep -q 'event.*system\|on(.*event\|lifecycle\|hook' pu.sh \
  && has "Event system / lifecycle hooks" "" \
  || missing "Event system / lifecycle hooks" "Pi: 20+ events (tool_call, context, etc.)"

grep -q 'pi install\|npm.*package\|plugin.*install' pu.sh \
  && has "Package manager (install from npm/git)" "" \
  || missing "Package manager" "Pi: pi install npm:pkg / git:repo"

grep -q 'skill\|SKILL\.md\|/skill' pu.sh \
  && has "Skills system" "" \
  || missing "Skills system" "Pi: /skill:name on-demand capabilities"

grep -q 'prompt.*template\|/template\|\.md.*expand' pu.sh \
  && has "Prompt templates" "" \
  || missing "Prompt templates" "Pi: /name expands reusable prompts"

grep -q 'theme\|THEME\|hot.reload.*style' pu.sh \
  && has "Themes" "" \
  || missing "Themes" "Pi: dark/light + custom, hot-reload"

grep -q 'registerCommand\|custom.*command\|/my' pu.sh \
  && has "Custom commands" "" \
  || missing "Custom commands" "Pi: pi.registerCommand()"

grep -q 'registerShortcut\|keybind\|keyboard.*shortcut' pu.sh \
  && has "Custom keyboard shortcuts" "" \
  || missing "Custom keyboard shortcuts" "Pi: customizable keybindings.json"

# ── 5. PROVIDERS ──
echo ""
printf "${B}─── Provider Support ───${N}\n"

grep -q 'anthropic' pu.sh && grep -q 'openai' pu.sh \
  && partial "Multi-provider" "2 providers (Anthropic + OpenAI)" \
  || missing "Multi-provider" "Pi: 20+ providers"

grep -q 'oauth\|/login\|subscription\|OAuth' pu.sh \
  && has "OAuth / subscription auth" "" \
  || missing "OAuth / subscription auth" "Pi: /login for Pro/Max subscriptions"

grep -q 'switch.*model\|/model\|model.*selector' pu.sh \
  && has "Mid-session model switching" "" \
  || missing "Mid-session model switching" "Pi: /model, Ctrl+L"

grep -q 'models\.json\|custom.*provider\|addProvider' pu.sh \
  && has "Custom provider registration" "" \
  || missing "Custom provider registration" "Pi: models.json for any API"

# ── 6. DEVELOPER EXPERIENCE ──
echo ""
printf "${B}─── Developer Experience ───${N}\n"

grep -q 'interactive\|TUI\|editor\|terminal.*ui\|ncurses' pu.sh \
  && has "Interactive TUI" "" \
  || missing "Interactive TUI" "Pi: full terminal UI with editor"

grep -q 'AGENTS\.md\|CLAUDE\.md\|context.*file' pu.sh \
  && has "Context files (AGENTS.md)" "" \
  || missing "Context files (AGENTS.md)" "Pi: auto-loads project instructions"

grep -q 'tab.*complet\|path.*complet' pu.sh \
  && has "Path completion" "" \
  || missing "Path completion" "Pi: Tab completes paths"

grep -q 'clipboard\|/copy\|pbcopy\|xclip' pu.sh \
  && has "Clipboard support" "" \
  || missing "Clipboard support" "Pi: /copy last response"

grep -q 'inline.*bash\|!command\|!!command' pu.sh \
  && has "Inline bash (!command)" "" \
  || missing "Inline bash (!command)" "Pi: !cmd sends output to LLM"

# ── 7. PROGRAMMATIC USE ──
echo ""
printf "${B}─── Programmatic Use ───${N}\n"

grep -q 'SDK\|createAgentSession\|import.*session' pu.sh \
  && has "SDK (embed in apps)" "" \
  || missing "SDK (embed in apps)" "Pi: TypeScript SDK"

grep -q 'rpc\|RPC\|stdin.*stdout.*json\|--mode rpc' pu.sh \
  && has "RPC mode (process integration)" "" \
  || missing "RPC mode" "Pi: --mode rpc JSONL over stdin/stdout"

grep -q 'mode.*json\|--mode json\|json.*output.*mode' pu.sh \
  && has "JSON output mode" "" \
  || missing "JSON output mode" "Pi: --mode json"

grep -q 'pipe\|--pipe\|PIPE' pu.sh \
  && has "Pipe/print mode" "--pipe" \
  || missing "Pipe/print mode" "Pi: -p print mode"

grep -q '! -t 0\|stdin\|cat$' pu.sh \
  && has "Stdin input" "" \
  || missing "Stdin input" ""

# ── 8. PORTABILITY (pu.sh advantages) ──
echo ""
printf "${B}─── Portability (pu.sh strengths) ───${N}\n"

SIZE=$(wc -c < pu.sh | tr -d ' ')
[ "$SIZE" -lt 25600 ] \
  && has "Under 25KB total ($SIZE bytes)" "Pi: ~10.5 MB npm unpacked" \
  || missing "Under 25KB" ""

head -1 pu.sh | grep -q '^#!/bin/sh' \
  && has "Shell-native (macOS + Linux, no runtime)" "Pi: Node.js but also Windows" \
  || missing "Shell-native" ""

# Windows support?
missing "Windows support" "Pi: native Windows, pu.sh: no sh"

! grep -qw 'node\|python3\|docker' pu.sh \
  && has "Zero heavy dependencies" "just sh + curl" \
  || missing "Zero heavy dependencies" ""

! grep -q 'config\.json\|settings\.json\|\.yaml' pu.sh \
  && has "Zero config files (env vars only)" "Pi: settings.json" \
  || missing "Zero config files" ""

grep -q 'pipe\|--pipe' pu.sh \
  && has "Pipe composition (agent|agent)" "unique to pu.sh" \
  || missing "Pipe composition" ""

# ══════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════
echo ""
printf "${B}══════════════════════════════════════════════════════${N}\n"
printf "${B}  RESULTS${N}\n"
printf "${B}══════════════════════════════════════════════════════${N}\n"
echo ""
printf "  ${G}Has:     %2d${N}  capabilities present\n" "$HAS"
printf "  ${Y}Partial: %2d${N}  partially implemented\n" "$PARTIAL"
printf "  ${R}Missing: %2d${N}  not implemented (Pi has them)\n" "$MISSING"
printf "  Total:   %2d  capabilities evaluated\n" "$TOTAL"
echo ""

SCORE=$(echo "scale=0; ($HAS * 100 + $PARTIAL * 50) / $TOTAL" | bc)
PI_SCORE=$(echo "scale=0; (($TOTAL - 5) * 100 + 5 * 50) / $TOTAL" | bc)
# Pi is missing the 5 portability-specific ones, partial on a few

printf "  pu.sh coverage: ${G}%d%%${N}\n" "$SCORE"
printf "  Pi coverage:       ${G}~92%%${N}  (missing: zero-install, shell-native, <25KB, zero-config, pipe-chain)\n"
echo ""
printf "  ${D}The gap: Pi has more features in a ~550× larger package.${N}\n"
printf "  ${D}pu.sh is 300 lines with zero deps beyond sh + curl.${N}\n"
echo ""
