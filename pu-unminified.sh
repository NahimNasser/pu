#!/bin/sh
# =============================================================================
# pu-unminified.sh — a readable, educational build of pu.sh
# =============================================================================
#
# This file is intentionally the opposite of a tiny/minified shell script.
# It uses the same executable function/variable surface as pu.sh so tests,
# stubs, and runtime behavior stay in lockstep; only spacing and comments are
# expanded for review.
#
# Goals of this version:
#
#   1. Behavioral parity: default limits, exposed commands, provider requests,
#      tool behavior, session mechanics, and sourceable helper names should
#      match pu.sh.
#   2. No extra runtime surface: pu-unminified.sh should not introduce extra
#      commands, helper APIs, or dependencies beyond pu.sh.
#   3. Educational comments: the major concepts in the script are documented in
#      plain language.
#   4. Readability only: pu-unminified.sh is not a separate product; it is a
#      commented, spacious twin for code review and teaching.
#
# Architecture overview
# ---------------------
#
# pu/pu-unminified is a single-file coding assistant. The core loop is:
#
#   - collect configuration (provider, model, API key, tool limits),
#   - load optional project context from README/docs/TODO/bugs/etc.,
#   - keep a JSON conversation history file,
#   - send the conversation to an LLM provider,
#   - parse tool calls from the model response,
#   - execute whitelisted local tools,
#   - append tool results back into the conversation,
#   - repeat until the model emits a final answer.
#
# Provider support
# ----------------
#
# The script can speak to multiple APIs:
#
#   - OpenAI Responses API
#   - Anthropic Messages API
#
# Because each provider has different JSON shapes, the script has a provider
# translation layer. The rest of the code can ask for "assistant text" and
# "tool calls" without caring which backend produced them.
#
# Tool sandbox model
# ------------------
#
# The assistant does not get arbitrary shell access through the model API.
# Instead, model tool calls are routed through run_tool(), which
# exposes a small set of built-in tools:
#
#   - read(path, offset, limit)
#   - write(path, content)
#   - edit(path, oldText, newText)
#   - grep(pattern, path)
#   - find(path, name)
#   - ls(path)
#   - bash(command)
#
# The script enforces path validation, blocks dangerous shell metacharacter
# patterns in bash commands, truncates output by default, and logs every event.
# pu-unminified.sh keeps the same default truncation ceilings as pu.sh so the
# readable build does not change runtime behavior.
#
# Conversation compaction
# -----------------------
#
# Long coding sessions can exceed model context windows. The context compaction
# helpers estimate token usage, retain recent history, preserve valid OpenAI tool
# call/result pairs, and optionally ask the model to summarize older history.
#
# Logging and replay
# ------------------
#
# Every run appends JSON events to .pu-events.jsonl. These events are useful for
# debugging, replaying terminal sessions, and exporting a session transcript to
# Markdown.
#
# File layout / table of contents
# -------------------------------
#
#   1. Terminal UI and signal handling
#   2. Configuration and environment loading
#   3. JSON helpers
#   4. Tool schema declarations
#   5. Provider request/response translation
#   6. Local tool dispatcher
#   7. Conversation persistence, replay, and export
#   8. Token accounting and status display
#   9. Context loading and compaction
#  10. Main agent loop
#  11. Prompt/skill helpers and interactive setup
#  12. CLI entrypoint
#
# Data flow
# ---------
#
#   User task
#      ↓
#   MSGS
#      ↓
#   call_api
#      ↓
#   raw provider JSON
#      ↓
#   parse_response
#      ↓
#   assistant text OR tool call
#      ↓
#   run_tool
#      ↓
#   tool result
#      ↓
#   append
#      ↓
#   repeat until final answer or MAX_STEPS
#
# Glossary
# --------
#
# Provider:
#   The LLM API backend, such as OpenAI or Anthropic.
#
# Tool call:
#   A structured request from the model asking this local script to run one of
#   the declared tools. The provider never directly runs local commands.
#
# Context:
#   The JSON conversation history sent to the model on each turn.
#
# Compaction:
#   The process of summarizing or trimming old conversation turns so a long
#   session can continue within the model's context window.
#
# Tool result pair:
#   Some providers require every tool request to be followed by a matching tool
#   result. The compaction code preserves these pairs so resumed conversations
#   remain valid provider input.
#
# Development note
# ----------------
#
# This is still shell. Comments and whitespace make the logic easier to follow,
# but the implementation intentionally remains dependency-light: POSIX shell,
# curl, awk/sed/grep/find, and common Unix tools.
#
# =============================================================================

# pu-unminified.sh — readable educational build of pu.sh. Usage: ./pu-unminified.sh "task" | ./pu-unminified.sh | ./pu-unminified.sh --pipe "review"
set -u
_STATE=idle _CHILD=0 SPIN_PID="" SPIN_MSG=""

# Spinner: paints a tiny progress indicator while network/API calls are running.
_spinner(){ tput civis >&2 2>/dev/null;
while :;
do for f in '[   ]' '[=  ]' '[== ]' '[===]' '[ ==]' '[  =]';
do printf '\r\033[K%s %s' "$f" "$SPIN_MSG" >&2;
sleep 0.15;
done;
done;
}
spin_start(){ [ -t 2 ]||return 0;
SPIN_MSG="$*";
[ -n "$SPIN_PID" ]&&return 0;
_spinner& SPIN_PID=$!;
}
spin_stop(){ [ -n "$SPIN_PID" ]&&{ kill "$SPIN_PID" 2>/dev/null;
wait "$SPIN_PID" 2>/dev/null;
SPIN_PID="";
};
[ -t 2 ]&&{ printf '\r\033[K' >&2;
tput cnorm >&2 2>/dev/null||true;
};
}

# Process cleanup: stop a process and its descendants after Ctrl-C or timeout.
_kill_tree(){ local p="$1" c;
[ -n "$p" ] && [ "$p" -gt 0 ] 2>/dev/null || return 0;
if command -v pgrep >/dev/null 2>&1;
then for c in $(pgrep -P "$p" 2>/dev/null);
do _kill_tree "$c";
done;
fi;
kill -TERM "$p" 2>/dev/null || true;
sleep 0.2;
if command -v pgrep >/dev/null 2>&1;
then for c in $(pgrep -P "$p" 2>/dev/null);
do _kill_tree "$c";
done;
fi;
kill -KILL "$p" 2>/dev/null || true;
}
_interrupt(){ spin_stop;
if [ "$_STATE" = busy ];
then [ $_CHILD -ne 0 ] && { _kill_tree "$_CHILD";
wait "$_CHILD" 2>/dev/null || true;
};
_CHILD=0;
_STATE=idle;
else exit 130;
fi;
}
trap '_interrupt' INT;
trap '' PIPE;

# API key hygiene: strip whitespace/quotes and normalize provider key input.
_clean_key(){ printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^export[[:space:]]*//;s/^OPENAI_API_KEY=//;s/^ANTHROPIC_API_KEY=//;s/^"//;s/"$//;s/^'\''//;
s/'\''$//' | tr -d '[:space:]';
}
_load_env(){ [ -f "$HOME/.pu.env" ] || return;
while IFS='=' read -r k v;
do k=$(printf '%s' "$k" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^export[[:space:]]*//');
v=$(_clean_key "$v");
case "$k" in OPENAI_API_KEY) [ -z "${OPENAI_API_KEY:-}" ] && OPENAI_API_KEY=$v;;
 ANTHROPIC_API_KEY) [ -z "${ANTHROPIC_API_KEY:-}" ] && ANTHROPIC_API_KEY=$v;;
 AGENT_PROVIDER) [ -z "${AGENT_PROVIDER:-}" ] && AGENT_PROVIDER=$v;;
 AGENT_MODEL) [ -z "${AGENT_MODEL:-}" ] && AGENT_MODEL=$v;;
 AGENT_EFFORT) [ -z "${AGENT_EFFORT:-}" ] && AGENT_EFFORT=$v;;
 esac;
done < "$HOME/.pu.env";
}
_load_env;
[ -n "${OPENAI_API_KEY:-}" ] && OPENAI_API_KEY=$(_clean_key "$OPENAI_API_KEY");
[ -n "${ANTHROPIC_API_KEY:-}" ] && ANTHROPIC_API_KEY=$(_clean_key "$ANTHROPIC_API_KEY")
if [ -n "${AGENT_PROVIDER:-}" ];
then PROVIDER=$AGENT_PROVIDER;
else case "${AGENT_MODEL:-}" in gpt-*|o1*|o3*|o4*) PROVIDER=openai;;
 claude-*) PROVIDER=anthropic;;
 *) [ -n "${OPENAI_API_KEY:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ] && PROVIDER=openai || PROVIDER=anthropic;;
 esac;
fi
case "$PROVIDER" in
  openai)
    MODEL="${AGENT_MODEL:-gpt-5.5}"
    ;;

  anthropic|*)
    MODEL="${AGENT_MODEL:-claude-opus-4-7}"
    ;;
esac

# Runtime limits and file locations.
#
# These names are intentionally long because pu-unminified.sh optimizes for teaching.
# In pu.sh these same ideas are represented by terse variables to keep the file
# compact.
MAX_STEPS="${AGENT_MAX_STEPS:-100}"
MAX_TOKENS="${AGENT_MAX_TOKENS:-4096}"
AGENT_RESERVE="${AGENT_RESERVE:-16000}"
AGENT_KEEP_RECENT="${AGENT_KEEP_RECENT:-80000}"

# Match pu.sh's default ceilings so this readable build is behavior-compatible.
AGENT_TOOL_TRUNC="${AGENT_TOOL_TRUNC:-100000}"
AGENT_READ_MAX="${AGENT_READ_MAX:-1000000}"

LOG="${AGENT_LOG:-.pu-events.jsonl}"
HISTORY="${AGENT_HISTORY-.pu-history.json}"
CONFIRM="${AGENT_CONFIRM:-0}"

CTX_LIMIT="${AGENT_CONTEXT_LIMIT:-400000}"
VERBOSE="${AGENT_VERBOSE:-1}"
THINKING="${AGENT_THINKING:-}"
EFFORT="${AGENT_EFFORT:-${AGENT_THINKING:-medium}}"
EFFORT_OK=0
case "$PROVIDER:$MODEL" in openai:gpt-5.5*) EFFORT_OK=1;; anthropic:claude-opus-4-7*) [ -z "${AGENT_CONTEXT_LIMIT:-}" ] && CTX_LIMIT=272000; EFFORT_OK=1;; anthropic:claude-opus-4-6*|anthropic:claude-sonnet-4-6*|anthropic:claude-opus-4-5*) EFFORT_OK=1;; esac

PIPE=0
COST=0
INTERACTIVE=0
MSGS=""
SYSTEM="${AGENT_SYSTEM:-You are an expert coding assistant. You can read, write, edit, grep, find, ls, and run bash.
Tools: read(path,offset,limit); bash(command); edit(path,oldText,newText); write(path,content); grep(pattern,path); find(path,name); ls(path).
Guidelines: prefer grep/find/ls over bash for exploration; working directory is $(pwd), do not cd in bash commands; combine related grep searches with alternation.
Use read instead of cat/sed; write only for new files or complete rewrites; edit only with exact unique oldText, reading surrounding lines after failures and never retrying the same failed oldText.
Before tool calls briefly say what you are checking/changing; be concise; show file paths clearly.
Current date: $(date +%Y-%m-%d)
Current working directory: $(pwd)
Your source code is at $(cd "$(dirname "$0")" && pwd)/$(basename "$0"). Use read to inspect it if asked about your capabilities/configuration.}"




while [ $# -gt 0 ];
do case "$1" in -h|--help) printf '%s\n' 'pu-unminified.sh — readable educational build of pu.sh (sh+curl, no deps)' 'Usage: ./pu-unminified.sh "task" | ./pu-unminified.sh (interactive) | --pipe | --cost | -v' 'Env: ANTHROPIC_API_KEY OPENAI_API_KEY AGENT_MODEL AGENT_PROVIDER AGENT_SYSTEM AGENT_MAX_STEPS AGENT_MAX_TOKENS AGENT_LOG AGENT_CONFIRM AGENT_VERBOSE AGENT_CONTEXT_LIMIT AGENT_RESERVE AGENT_TOOL_TRUNC AGENT_READ_MAX AGENT_HISTORY AGENT_THINKING/AGENT_EFFORT AGENT_PRICE_* ~/.pu.env' '7 tools, multi-turn, retries, JSONL logging, pipe mode, !command; auto-compaction summarizes older turns; /compact [focus] runs it manually.';
exit 0;;
-v|--version)echo "pu-unminified.sh 1.0.0";
exit 0;;
--pipe|-p)PIPE=1;
shift;;
--cost)COST=1;
shift;;
-i)INTERACTIVE=1;
shift;;
-n|--no-interactive)INTERACTIVE=-1;
shift;;
*)break;;
esac;
done
for _dep in curl awk;
do command -v $_dep >/dev/null 2>&1||{ printf '\033[31m[!] %s not found\033[0m\n' "$_dep" >&2;
exit 1;
};
done
RUNSH=$(command -v bash 2>/dev/null||echo sh)

# JSON helper: read a single field using awk. This avoids requiring jq while
# still giving the rest of the script a small, dependency-light JSON primitive.
jp(){
  printf '%s' "$1" | awk -v k="$2" '
  function hx(c){c=tolower(c);return index("0123456789abcdef",c)-1}
  function h4(s){return hx(substr(s,1,1))*4096+hx(substr(s,2,1))*256+hx(substr(s,3,1))*16+hx(substr(s,4,1))}
  function u8(n){if(n<128)return sprintf("%c",n);if(n<2048)return sprintf("%c%c",192+int(n/64),128+n%64);if(n<65536)return sprintf("%c%c%c",224+int(n/4096),128+int(n/64)%64,128+n%64);return sprintf("%c%c%c%c",240+int(n/262144),128+int(n/4096)%64,128+int(n/64)%64,128+n%64)}
  function uniu(s, r,p,h,n,n2){r="";while((p=index(s,"\\u"))>0&&length(s)>=p+5){h=substr(s,p+2,4);if(h!~/^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/){r=r substr(s,1,p+1);s=substr(s,p+2);continue};r=r substr(s,1,p-1);n=h4(h);if(n>=55296&&n<=56319&&substr(s,p+6,2)=="\\u"){h=substr(s,p+8,4);if(h~/^[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]$/){n2=h4(h);if(n2>=56320&&n2<=57343){n=65536+(n-55296)*1024+(n2-56320);s=substr(s,p+12);r=r u8(n);continue}}};r=r u8(n);s=substr(s,p+6)};return r s}
  BEGIN{RS="\001"}{
    tgt="\"" k "\"" ":"
    n=index($0,tgt); if(n==0){print "";exit}
    s=substr($0,n+length(tgt)); sub(/^[[:space:]]*/,"",s)
    c=substr(s,1,1)
    if(c=="\""){
      s=substr(s,2); o=""
      while(1){
        p=index(s,"\""); if(p==0){o=o s;break}
        pre=substr(s,1,p-1); bs=0
        for(i=length(pre);i>=1;i--){if(substr(pre,i,1)=="\\")bs++;else break}
        o=o substr(s,1,p-1)
        if(bs%2==1){o=o "\"";s=substr(s,p+1);continue}; break
      }
      gsub(/\\\\/,"\001",o); gsub(/\\n/,"\n",o); gsub(/\\t/,"\t",o); gsub(/\\r/,"\r",o); o=uniu(o); gsub(/\\"/,"\"",o); gsub(/\001/,"\\",o)
      printf "%s",o
    } else if(c=="[" || c=="{"){
      d=1; s=substr(s,2); o=c; q=0; e=0
      while(d>0 && length(s)>0){
        c2=substr(s,1,1); s=substr(s,2); o=o c2
        if(e){e=0;continue}; if(c2=="\\"){e=1;continue}
        if(c2=="\""){q=!q;continue}; if(q)continue
        if(c2=="{" || c2=="[")d++; else if(c2=="}" || c2=="]")d--
      }; print o
    } else { match(s,/^[^,}\]]+/); print substr(s,1,RLENGTH) }
  }'
}
jb(){
  printf '%s' "$1" | awk -v t="$2" 'BEGIN{RS="\001"}{
    n=index($0,"\"" t "\""); if(n==0){print "";exit}
    for(i=n-1;i>=1;i--) if(substr($0,i,1)=="{") break
    s=substr($0,i); d=0; o=""; q=0; e=0
    for(j=1;j<=length(s);j++){
      c=substr(s,j,1); o=o c
      if(e){e=0;continue}; if(c=="\\"){e=1;continue}
      if(c=="\""){q=!q;continue}; if(q)continue
      if(c=="{")d++; else if(c=="}")d--
      if(d==0)break
    }; print o
  }'
}

# Tool-call helper: split a provider response into individual tool-use JSON objects.
each_tool_use(){ printf '%s' "$1" | awk -v m="$2" 'BEGIN{RS="\001"}{s=$0
  while((p=index(s,m))>0){
    for(i=p-1;i>=1;i--) if(substr(s,i,1)=="{") break
    d=0;q=0;e=0;o=""
    for(j=i;j<=length(s);j++){c=substr(s,j,1);o=o c
      if(e){e=0;continue}; if(c=="\\"){e=1;continue}
      if(c=="\""){q=!q;continue}; if(q)continue
      if(c=="{")d++; else if(c=="}")d--; if(d==0)break}
    print o; s=substr(s,j+1)}}';
}

# Provider parser: normalize OpenAI response output items into one stream.
oa_items(){ printf '%s' "$1" | awk 'BEGIN{RS="\001"}{d=0;q=0;e=0;for(i=1;i<=length($0);i++){c=substr($0,i,1);if(e){e=0;continue};if(c=="\\"){e=1;continue};if(c=="\""){q=!q;continue};if(q)continue;if(c=="{"){if(d==0)s=i;d++}else if(c=="}"){d--;if(d==0){o=substr($0,s,i-s+1);if(o~/"type"[ ]*:[ ]*"reasoning"/||o~/"type"[ ]*:[ ]*"function_call"/)print o}}}}';
}

# JSON helper: safely encode arbitrary text as a JSON string.
json_escape(){ printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037' | awk '{gsub(/\\/,"\\\\")} {gsub(/"/,"\\\"")} {gsub(/\t/,"\\t")} {gsub(/\r/,"\\r")} NR>1{printf "\\n"} {printf "%s",$0}';
}

# Terminal UI helpers: colorized status, error, debug, and assistant text output.
info(){ [ "$PIPE" = 0 ] && printf '\r\033[K\033[36m[pu-unminified]\033[0m %s\n' "$*" >&2 || true;
}
err(){ printf '\r\033[K\033[31m[!] %s\033[0m\n' "$*" >&2;
}
dbg(){ [ "$VERBOSE" = 1 ] && printf '\r\033[K[v] %s\n' "$*" >&2 || true;
}
_p(){ case "$1" in "$PWD"/*) printf '%s' "${1#"$PWD"/}";;
 "$HOME"/*) printf '~%s' "${1#"$HOME"}";;
 *) printf '%s' "$1";;
 esac;
}
_tool(){ [ "$PIPE" = 0 ] && printf '\r\033[K\033[2m⏺\033[0m \033[36m%s\033[0m \033[2m%s\033[0m\n' "$1" "$2" >&2 || true;
}
_say(){ [ "$PIPE" = 0 ] && printf '\r\033[K%s\n' "$1" >&2 || true;
}
_mkparent(){ local d;
d=$(dirname "$1");
[ -n "$d" ] && [ "$d" != . ] && mkdir -p "$d" 2>/dev/null || true;
}

# Event logging: append timestamped JSON objects to the project event log.
log(){ _mkparent "$LOG";
printf '{"s":%s,"t":"%s","c":"%s"}\n' "$1" "$2" "$(json_escape "$3")" >> "$LOG";
}
_num(){ case "$2" in ''|*[!0-9]*) err "$1 must be a non-negative integer";
exit 1;;
 esac;
}
for _nv in MAX_STEPS:$MAX_STEPS MAX_TOKENS:$MAX_TOKENS CTX_LIMIT:$CTX_LIMIT AGENT_RESERVE:$AGENT_RESERVE AGENT_KEEP_RECENT:$AGENT_KEEP_RECENT AGENT_TOOL_TRUNC:$AGENT_TOOL_TRUNC AGENT_READ_MAX:$AGENT_READ_MAX;
do _num "${_nv%%:*}" "${_nv#*:}";
done
[ "$CTX_LIMIT" -gt "$AGENT_RESERVE" ] || { err "AGENT_CONTEXT_LIMIT must be greater than AGENT_RESERVE";
exit 1;
}
# Tool schema declarations
# ------------------------
#
# The provider receives these JSON schemas. They tell the model which tools it
# may request and which JSON arguments each tool accepts.
#
# Example tool-call payloads the model might produce:
#
#   read:
#     {"path":"README.md","offset":1,"limit":80}
#
#   edit:
#     {"path":"main.py","oldText":"print('hello')","newText":"print('hello world')"}
#
#   grep:
#     {"pattern":"TODO|FIXME","path":"."}
#
# The provider-specific tool wrapper JSON differs, but the core schemas are the
# same for Anthropic and OpenAI.
SP='{"type":"object","properties":{"command":{"type":"string","description":"Shell command"}},"required":["command"]}'
RP='{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"Start line"},"limit":{"type":"integer","description":"Max lines"}},"required":["path"]}'
WP='{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}'
EP='{"type":"object","properties":{"path":{"type":"string"},"oldText":{"type":"string","description":"Exact text to find"},"newText":{"type":"string","description":"Replacement"}},"required":["path","oldText","newText"]}'
GP='{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}'
FP='{"type":"object","properties":{"path":{"type":"string"},"name":{"type":"string","description":"Glob"}},"required":["path"]}'
LP='{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}'
TD='{"name":"bash","description":"Run a shell command","input_schema":'$SP'},{"name":"read","description":"Read file contents","input_schema":'$RP'},{"name":"write","description":"Write content to file, creates dirs","input_schema":'$WP'},{"name":"edit","description":"Edit file with exact text replacement","input_schema":'$EP'},{"name":"grep","description":"Search for pattern in files","input_schema":'$GP'},{"name":"find","description":"Find files by name glob","input_schema":'$FP'},{"name":"ls","description":"List directory","input_schema":'$LP'}'
TF='{"type":"function","function":{"name":"bash","description":"Run a shell command","parameters":'$SP'}},{"type":"function","function":{"name":"read","description":"Read file contents","parameters":'$RP'}},{"type":"function","function":{"name":"write","description":"Write content to file","parameters":'$WP'}},{"type":"function","function":{"name":"edit","description":"Edit file with exact text replacement","parameters":'$EP'}},{"type":"function","function":{"name":"grep","description":"Search for pattern","parameters":'$GP'}},{"type":"function","function":{"name":"find","description":"Find files","parameters":'$FP'}},{"type":"function","function":{"name":"ls","description":"List directory","parameters":'$LP'}}'
RF='{"type":"function","name":"bash","description":"Run a shell command","parameters":'$SP',"strict":false},{"type":"function","name":"read","description":"Read file contents","parameters":'$RP',"strict":false},{"type":"function","name":"write","description":"Write content to file","parameters":'$WP',"strict":false},{"type":"function","name":"edit","description":"Edit file with exact replacement","parameters":'$EP',"strict":false},{"type":"function","name":"grep","description":"Search for pattern","parameters":'$GP',"strict":false},{"type":"function","name":"find","description":"Find files","parameters":'$FP',"strict":false},{"type":"function","name":"ls","description":"List directory","parameters":'$LP',"strict":false}'

# Provider feature negotiation: construct optional thinking/reasoning parameters.
think_param(){ case "$PROVIDER:$MODEL" in anthropic:claude-opus-4-7*|anthropic:claude-opus-4-6*|anthropic:claude-sonnet-4-6*|anthropic:claude-opus-4-5*) echo ',"effort":"'$EFFORT'","thinking":{"type":"adaptive"}';;
 *) case "$THINKING" in low) echo ',"thinking":{"type":"enabled","budget_tokens":1024}';;
medium) echo ',"thinking":{"type":"enabled","budget_tokens":4096}';;
high|xhigh|max) echo ',"thinking":{"type":"enabled","budget_tokens":10000}';;
*) echo '';;
esac;;
 esac;
}

# call_api
# -----------------
# Sends the current conversation to the selected model provider.
#
# Inputs:
#   $1 - JSON array of conversation messages.
#
# Reads globals:
#   PROVIDER, MODEL, SYSTEM, MAX_TOKENS, THINKING,
#   EFFORT, and the provider API key environment variable.
#
# Output:
#   Raw provider JSON response on stdout.
#
# Why this exists:
#   OpenAI and Anthropic accept different request shapes. This function is the
#   adapter that turns pu-unminified.sh's shared conversation JSON into the correct API
#   payload for the currently selected provider.
call_api(){ local sys_esc;
sys_esc=$(json_escape "$SYSTEM");
local tp mt=$MAX_TOKENS eb="${THINKING:-}";
tp=$(think_param)
  [ "$EFFORT_OK" = 1 ] && eb="${eb:-$EFFORT}";
case "$eb" in minimal|low) [ $mt -lt 4096 ] && mt=4096;;
 medium) [ $mt -lt 8192 ] && mt=8192;;
 high) [ $mt -lt 16000 ] && mt=16000;;
 xhigh|max) [ $mt -lt 32000 ] && mt=32000;;
 esac
  case "$PROVIDER" in
  anthropic) curl -sS -m120 \
    -H "x-api-key: ${ANTHROPIC_API_KEY:-}" \
    -H anthropic-version:2023-06-01 \
    -H content-type:application/json \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":$mt,\"system\":\"$sys_esc\",\"tools\":[$TD],\"messages\":$1${tp}}" \
    https://api.anthropic.com/v1/messages 2>&1;;

  openai) local rp='';
[ "$EFFORT_OK" = 1 ] && case "$EFFORT" in ''|none) ;;
 *) rp=',"reasoning":{"effort":"'$EFFORT'"}';;
 esac
    curl -sS -m120 \
    -H "Authorization: Bearer ${OPENAI_API_KEY:-}" \
    -H content-type:application/json \
    -d "{\"model\":\"$MODEL\",\"max_output_tokens\":$mt${rp},\"instructions\":\"$sys_esc\",\"input\":$1,\"tools\":[$RF]}" \
    https://api.openai.com/v1/responses 2>&1;;

  esac;
}

# parse_response
# -----------------------
# Converts provider-specific response JSON into a small set of global parse
# variables used by run_task.
#
# Anthropic tool-call shape, simplified:
#
#   {"content":[{"type":"tool_use","id":"...","name":"read","input":{...}}]}
#
# OpenAI Responses tool-call shape, simplified:
#
#   {"output":[{"type":"function_call","call_id":"...","name":"read","arguments":"{...}"}]}
#
# Output globals:
#   TY       T for tool request, X for final text.
#   TN           Tool name such as read, edit, grep, or bash.
#   TI        Provider call identifier used to pair results.
#   TINP     JSON arguments for the tool.
#   TX      Assistant text, if any.
#   CB / TC
#                              Provider-native blocks kept for valid history.
parse_response(){ local resp="$1";
TY= TN= TI= TX= CB= TINP= TC=
  if [ "$PROVIDER" = anthropic ];
then
    local tu;
tu=$(jb "$resp" "tool_use")
    if [ -n "$tu" ];
then
      TY=T;
TN=$(jp "$tu" name);
TI=$(jp "$tu" id);
TINP=$(jp "$tu" input)
      local tt;
tt=$(jb "$resp" "text");
TX=$(jp "$tt" text)
      CB=$(jp "$resp" content)
    else
      TY=X;
local tt;
tt=$(jb "$resp" "text");
TX=$(jp "$tt" text)
    fi
  else
    TC=$(jp "$resp" output);
local call;
call=$(jb "$TC" function_call)
    if [ -n "$call" ];
then
      TY=T;
TI=$(jp "$call" call_id);
[ -z "$TI" ] && TI=$(jp "$call" id)
      TN=$(jp "$call" name);
TINP=$(jp "$call" arguments);
local tt;
tt=$(jb "$resp" output_text);
TX=$(jp "$tt" text);
[ -z "$TX" ] && TX=$(jp "$resp" output_text)
    else
      TY=X;
local tt;
tt=$(jb "$resp" output_text);
TX=$(jp "$tt" text);
[ -z "$TX" ] && TX=$(jp "$resp" output_text);
TC=
    fi
  fi;
}

# run_tool
# ------------------
# Validates and executes the small built-in tool set.
#
# Why tools are explicit:
#   The model cannot directly execute host actions. It can only request one of
#   the names declared in the provider request. This function remains the local
#   authority for what happens next.
#
# This means the script controls:
#   - which tools exist,
#   - how paths are interpreted,
#   - whether writes are atomic,
#   - how much output is returned,
#   - whether user confirmation is required.
run_tool(){ local tool_name="$1" input="$2"
  [ "$CONFIRM" = 1 ] && { { : </dev/tty;
} 2>/dev/null || { echo "[denied: no tty]";
return 0;
}
    printf '\033[33m[?] %s: %s\033[0m [y/N] ' "$tool_name" "$(printf '%s' "$input" | head -c 80)" >&2
    read -r yn </dev/tty;
[ "$yn" = y ] || [ "$yn" = Y ] || { echo "[denied]";
return 0;
};
}
  local out="" rc=0
  case "$tool_name" in
    # bash: run a command through the configured shell. Commands are written to
    # a temporary script file so multi-line commands behave naturally.
    bash)
      local cmd;
cmd=$(jp "$input" command);
_tool bash "$cmd"
      local tf;
tf=$(mktemp);
printf '%s\n' "$cmd" > "$tf"
      out=$("$RUNSH" "$tf" 2>&1) && rc=0 || rc=$?;
rm -f "$tf"
      [ $rc -ne 0 ] && out="$out
[exit:$rc]";;

    # read: return a whole file or a line range. In pu-unminified.sh the default
    # whole-file byte limit is intentionally enormous for teaching/demo use.
    read)
      local fp;
fp=$(jp "$input" path);
case "$fp" in -*) fp="./$fp";;
 esac
      local off;
off=$(jp "$input" offset);
[ "$off" = 0 ] && off=1
      local lim;
lim=$(jp "$input" limit);
_tool read "$(_p "$fp")"
      if [ -f "$fp" ];
then
        case "$off" in ""|*[!0-9]*) [ -z "$off" ] || { out="Error: offset must be a positive integer";
rc=1;
};;
 0) off=1;;
 esac
        case "$lim" in ""|*[!0-9]*) [ -z "$lim" ] || { out="Error: limit must be a positive integer";
rc=1;
};;
 0) out="";
rc=0;;
 esac
        if [ $rc -eq 0 ] && [ "$lim" = 0 ];
then :
        elif [ $rc -eq 0 ];
then local sz;
sz=$(wc -c < "$fp")
          if [ -z "$off" ] && [ -z "$lim" ] && [ "$sz" -gt "$AGENT_READ_MAX" ];
then
            out="Error: $fp is $sz bytes — pass offset/limit to read a range";
rc=1
          elif [ -n "$off" ] && [ -n "$lim" ];
then out=$(sed -n "${off},$((off+lim-1))p" "$fp")
          elif [ -n "$off" ];
then out=$(sed -n "${off},\$p" "$fp")
          elif [ -n "$lim" ];
then out=$(head -n "$lim" "$fp")
          else out=$(cat "$fp");
fi
        fi
      else out="Error: file not found: $fp";
rc=1;
fi;;

    # write: atomic-ish file replacement. Content goes to a temp file first,
    # then mv replaces the target while preserving permissions where possible.
    write)
      local fp;
fp=$(jp "$input" path);
case "$fp" in -*) fp="./$fp";;
 esac
      local ct;
ct=$(jp "$input" content;
printf x);
ct=${ct%x}
      _tool write "$(_p "$fp")"
      [ -L "$fp" ] && { local l;
l=$(readlink "$fp") || { out="Error reading symlink: $fp";
rc=1;
};
[ $rc -eq 0 ] && case "$l" in /*) fp=$l;;
 *) fp="$(dirname "$fp")/$l";;
 esac;
}
      if [ $rc -ne 0 ];
then :
      elif case "$ct" in *"to=functions."*|*"<|channel|>"*|*"<|start|>assistant"*) true;; *) false;; esac;
then
        out="Error: content contains harmony channel markers (likely model CoT leakage); refusing write";
rc=1
      elif ! mkdir -p "$(dirname "$fp")" 2>/dev/null;
then
        out="Error creating directory for $fp";
rc=1
      else
        local tmp mode um;
tmp=$(mktemp "$(dirname "$fp")/.pu.XXXXXX") || { out="Error creating temp file";
rc=1;
}
        if [ $rc -eq 0 ];
then
          if [ -e "$fp" ];
then mode=$(stat -f %Lp "$fp" 2>/dev/null || stat -c %a "$fp" 2>/dev/null || true);
else um=$(umask);
mode=$(printf '%03o' $((0666 & ~0$um)));
fi
          [ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null || true
          printf '%s' "$ct" > "$tmp" && mv "$tmp" "$fp" && out="Wrote to $fp" || { rm -f "$tmp";
out="Error writing $fp";
rc=1;
}
        fi
      fi;;

    # edit: exact single-match replacement. This deliberately fails when the
    # oldText block is missing or appears multiple times, preventing blind edits.
    edit)
      local fp;
fp=$(jp "$input" path);
case "$fp" in -*) fp="./$fp";;
 esac
      local old;
old=$(jp "$input" oldText;
printf x);
old=${old%x}
      local new;
new=$(jp "$input" newText;
printf x);
new=${new%x}
      _tool edit "$(_p "$fp")"
      [ -L "$fp" ] && { local l;
l=$(readlink "$fp") || { out="Error reading symlink: $fp";
rc=1;
};
[ $rc -eq 0 ] && case "$l" in /*) fp=$l;;
 *) fp="$(dirname "$fp")/$l";;
 esac;
}
      if [ $rc -ne 0 ];
then :
      elif [ -z "$old" ];
then out="Error: oldText must not be empty";
rc=1
      elif case "$new" in *"to=functions."*|*"<|channel|>"*|*"<|start|>assistant"*) true;; *) false;; esac;
then out="Error: newText contains harmony channel markers (likely model CoT leakage); refusing edit";
rc=1
      elif [ -f "$fp" ];
then
        local tmp mode;
tmp=$(mktemp "$(dirname "$fp")/.pu.XXXXXX") || { out="Error creating temp file";
rc=1;
}
        mode=$(stat -f %Lp "$fp" 2>/dev/null || stat -c %a "$fp" 2>/dev/null || true);
[ -n "$mode" ] && chmod "$mode" "$tmp" 2>/dev/null || true
        OLD="$old" NEW="$new" awk 'BEGIN{RS="\001";ORS="";o=ENVIRON["OLD"];n=ENVIRON["NEW"]}{s=$0;c=0;while((i=index(s,o))>0){c++;s=substr(s,i+length(o))}if(c!=1)exit c?2:1;i=index($0,o);printf "%s%s%s",substr($0,1,i-1),n,substr($0,i+length(o))}' "$fp" > "$tmp" \
          && { mv "$tmp" "$fp";
out="Edited $fp";
} \
          || { rc=$?;
rm -f "$tmp";
[ $rc -eq 2 ] && out="Error: oldText matched multiple times in $fp. Use a larger unique oldText block." || out="Error: oldText not found in $fp. Read exact surrounding lines before retrying; do not retry the same oldText.";
rc=1;
}
      else out="Error: file not found: $fp";
rc=1;
fi;;

    # grep: recursive search that skips common dependency/build directories.
    # Match pu.sh by returning the first 100 matching lines.
    grep)
      local pat;
pat=$(jp "$input" pattern)
      local gp;
gp=$(jp "$input" path);
[ -z "$gp" ] && gp="."
      _tool grep "$pat $(_p "$gp")"
      case "$gp" in -*) gp="./$gp";;
 esac
      out=$(grep -rnIE --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=dist --exclude-dir=build --exclude-dir=target --exclude-dir=.venv -- "$pat" "$gp" 2>&1);
rc=$?;
[ $rc -eq 1 ] && { out="No matches";
rc=0;
};
out=$(printf '%s\n' "$out" | awk 'NR<=100');;

    # find: file discovery with the same dependency/build directory pruning.
    # Match pu.sh by returning the first 100 discovered paths.
    find)
      local fp;
fp=$(jp "$input" path);
[ -z "$fp" ] && fp="."
      local fn;
fn=$(jp "$input" name)
      _tool find "$(_p "$fp") $fn"
      case "$fp" in -*) fp="./$fp";;
 esac
      if [ -n "$fn" ];
then out=$(find "$fp" \( -name .git -o -name node_modules -o -name dist -o -name build -o -name target -o -name .venv \) -prune -o -name "$fn" -print 2>&1 | head -100);
else out=$(find "$fp" \( -name .git -o -name node_modules -o -name dist -o -name build -o -name target -o -name .venv \) -prune -o -print 2>&1 | awk -v root="$fp" '{p=$0;if(index(p,root)==1){p=substr(p,length(root)+1);sub("^/","",p)};n=gsub("/","/",p);if(p==""||n<3)print}' | head -100);
fi;;

    # ls: directory inspection. Kept simple because the model already receives
    # structured guidance about when to prefer ls/find/grep over bash.
    ls)
      local lp;
lp=$(jp "$input" path);
[ -z "$lp" ] && lp="."
      _tool ls "$(_p "$lp")";
case "$lp" in -*) lp="./$lp";;
 esac;
out=$(ls -la "$lp" 2>&1) || rc=$?;;

    *)
      out="Error: unknown tool: $tool_name";
rc=1;;

  esac
  M="$AGENT_TOOL_TRUNC";
[ "$tool_name" != read ] && [ ${#out} -gt "$M" ] && out="$(printf '%s\n' "$out" | awk '{a[NR]=$0}END{if(NR<=40){for(i=1;i<=NR;i++)print a[i];exit}for(i=1;i<=30;i++)print a[i];printf "...[%d lines hidden;
call read with offset/limit to view a specific range]...\n",NR-40;for(i=NR-9;i<=NR;i++)print a[i]}')"
  printf '%s' "$out";
}

# Persistence: save/load the JSON conversation history used between turns.
save(){ [ -n "$HISTORY" ] && { _mkparent "$HISTORY";
printf '%s' "$MSGS" > "$HISTORY";
printf '%s:%s' "$PROVIDER" "$MODEL" > "$HISTORY.meta";
} || true;
}
load(){ [ -n "$HISTORY" ] && [ -f "$HISTORY" ] && [ -f "$HISTORY.meta" ] && [ "$(cat "$HISTORY.meta")" = "$PROVIDER:$MODEL" ] && MSGS=$(cat "$HISTORY") && case "$MSGS" in \[*\]) [ "$MSGS" != "[]" ] && return 0;;
 esac;
MSGS="";
return 1;
};

# Replay/export helpers: reconstruct a readable session from .pu-events.jsonl.
_replay(){ [ "$INTERACTIVE" = 1 ] && [ -f "$LOG" ] || return;
info "Last messages from $LOG:";
tail -200 "$LOG" | awk '/"t":"start"/{b=""}{b=b $0 "\n"}END{printf "%s",b}' | while IFS= read -r l;
do t=$(jp "$l" t);
c=$(jp "$l" c);
case "$t" in start) printf '\033[36m>\033[0m %s\n' "$c";;
 response) printf '%s\n' "$c";;
 tool_call) printf '⏺ %s\n' "$c";;
 error|max_steps) err "$c";;
 esac;
done >&2;
}

# Conversation builder: append user/assistant/tool messages to the JSON transcript.
append(){ [ "$MSGS" = "[]" ] && MSGS="[$1]" || MSGS=$(printf '%s' "$MSGS" | sed 's/]$//')",$1]";
}
RA='"role":"assistant"' RU='"role":"user"' RT='"role":"tool"'
TOKEN_IN=0 TOKEN_OUT=0 COST_USD=0
track_tokens(){ local u a b;
u=$(jp "$1" usage)
  case "$PROVIDER" in anthropic) a=$(jp "$u" input_tokens);
b=$(jp "$u" output_tokens);;
 *) a=$(jp "$u" input_tokens);
b=$(jp "$u" output_tokens);
[ -z "$a" ] && a=$(jp "$u" prompt_tokens);
[ -z "$b" ] && b=$(jp "$u" completion_tokens);;
 esac
  TOKEN_IN=$((TOKEN_IN+${a:-0}));
TOKEN_OUT=$((TOKEN_OUT+${b:-0}))
  COST_USD=$(awk -v c="$COST_USD" -v a="${a:-0}" -v b="${b:-0}" -v pi="${AGENT_PRICE_IN_PER_MTOK:-0}" -v po="${AGENT_PRICE_OUT_PER_MTOK:-0}" 'BEGIN{printf "%.6f",c+(a*pi+b*po)/1000000}') ;
}
_fmtk(){ awk -v n="$1" 'BEGIN{if(n>=1000000)printf "%.1fM",n/1000000;else if(n>=1000)printf "%.0fk",n/1000;else printf "%d",n}';
}
_ctxp(){ awk -v n="${#MSGS}" -v c="$CTX_LIMIT" 'BEGIN{printf "%.1f%%/%dk",(c?100*n/c:0),c/1000}';
}
_branch(){ command -v git >/dev/null 2>&1 && git branch --show-current 2>/dev/null | awk 'NF{printf " (%s)",$0}';
}
_status(){ local d;
case "$PWD" in "$HOME"/*) d="~/${PWD#"$HOME"/}";;
 *) d="$PWD";;
 esac;
printf '%s%s ↑%s ↓%s' "$d" "$(_branch)" "$(_fmtk "$TOKEN_IN")" "$(_fmtk "$TOKEN_OUT")";
[ "$COST" = 1 ] && printf ' $%.3f' "$COST_USD";
printf ' %s (%s) %s' "$(_ctxp)" "$PROVIDER" "$MODEL";
[ "$EFFORT_OK" = 1 ] && printf ' • %s' "$EFFORT";
}
_ctx_entries(){ printf '%s' "$1" | awk '
  BEGIN{RS="\001"; max=12000; outmax=4000; pending=""; ptype=""}
  function balanced(s, i,c,q,e,d){d=0;q=0;e=0;for(i=1;i<=length(s);i++){c=substr(s,i,1);if(e){e=0;continue};if(c=="\\"){if(q)e=1;continue};if(c=="\""){q=!q;continue};if(q)continue;if(c=="{")d++;else if(c=="}")d--}return d==0&&!q}
  function callid(s, t){if(match(s,/"call_id"[ \t]*:[ \t]*"[^"]+"/)){t=substr(s,RSTART,RLENGTH);sub(/^.*"call_id"[ \t]*:[ \t]*"/,"",t);sub(/"$/,"",t);return t}return "omitted"}
  function outstub(s){return "{\"type\":\"function_call_output\",\"call_id\":\"" callid(s) "\",\"output\":\"[large or malformed tool output omitted during compaction: " length(s) " chars]\"}"}
  function msgstub(s){return "{\"role\":\"user\",\"content\":\"[large or malformed message omitted during compaction: " length(s) " chars]\"}"}
  function emit(e){if(e~/^\{[ \t]*"type"[ \t]*:[ \t]*"function_call_output"/){if(length(e)<=outmax&&balanced(e))print e;else print outstub(e)}else if(e~/^\{[ \t]*"(role|id|type)"/){if(length(e)<=max&&balanced(e))print e;else if(e~/^\{[ \t]*"role"/)print msgstub(e)}}
  {data=$0;sub(/^\[/,"",data);sub(/\]$/,"",data);n=split(data,a,/\},\{/);for(i=1;i<=n;i++){raw=a[i]
    if(pending!=""){pending=pending "},{" raw; cand=pending; if(i<n)cand=cand "}"; if(length(cand)>max){if(ptype=="role")print msgstub(cand); pending=""; ptype=""; continue}; if(balanced(cand)){print cand; pending=""; ptype=""}; continue}
    e=(i>1?"{":"") raw; cand=e; if(i<n)cand=cand "}"; if(cand~/^\{[ \t]*"type"[ \t]*:[ \t]*"function_call_output"/){if(length(cand)<=outmax&&balanced(cand))print cand;else print outstub(cand); continue}
    if(cand~/^\{[ \t]*"(role|id|type)"/ && !balanced(cand) && length(cand)<=max){pending=e; ptype=(cand~/^\{[ \t]*"role"/?"role":"other"); continue}; emit(cand)}}'
}
_ctx_filter_openai_pairs(){ printf '%s\n' "$1" | awk '
  function callid(s, t){if(match(s,/"call_id"[ \t]*:[ \t]*"[^"]+"/)){t=substr(s,RSTART,RLENGTH);sub(/^.*"call_id"[ \t]*:[ \t]*"/,"",t);sub(/"$/,"",t);return t}return ""}
  {id=callid($0); if($0~/^\{.*"type"[ \t]*:[ \t]*"function_call"/ && $0!~/^\{.*"type"[ \t]*:[ \t]*"function_call_output"/){if(id!="")seen[id]=1; print; next}; if($0~/^\{.*"type"[ \t]*:[ \t]*"function_call_output"/){if(id!="" && seen[id])print; next}; print}' ;
}
_ctx_valid(){ local x="$1" cap="$2";
case "$x" in \[*\]) ;;
 *) return 1;;
 esac;
[ ${#x} -le "$cap" ] || return 1;
case "$x" in *',,'*|'[,'*|*',]'*) return 1;;
 esac;
return 0;
}
_ctx_local_memory(){ local mid="$1" f="${2:-}";
{ [ -n "$f" ] && printf 'Focus: %s\n' "$f";
printf '%s\n' "$mid" | awk 'BEGIN{print "Goal:";u=0;print "User constraints/directives:"}/"role":"user"/ && u<8 {s=$0;gsub(/\\n/," ",s);gsub(/\\"/,"\"",s);if(length(s)>260)s=substr(s,1,260)"...";print "- " s;u++}END{print "Files read:"}'
  printf '%s\n' "$mid" | grep -Eo '"path":"[^"]+"' 2>/dev/null | sed 's/^"path":"/- /;s/"$//' | awk '!seen[$0]++' | head -20;
printf 'Files changed:\n';
printf '%s\n' "$mid" | grep -E '"name":"(write|edit)"|Wrote to |Edited ' 2>/dev/null | head -20 | sed 's/^/- /'
  printf 'Commands run:\n';
printf '%s\n' "$mid" | grep -Eo '"command":"[^"]+"' 2>/dev/null | sed 's/^"command":"/- /;s/"$//' | head -20;
printf 'Errors/failures:\n';
printf '%s\n' "$mid" | grep -E 'Error:|\[exit:[0-9]+\]|\[denied\]|failed|Failed' 2>/dev/null | head -30 | sed 's/^/- /'
  printf 'Decisions made:\n- See retained recent transcript for latest decisions.\nImportant snippets/facts:\n- Older bulky tool output may have been omitted; re-read files from disk as needed.\nOpen TODOs / next steps:\n- Continue from the latest retained user request and recent transcript.\n';
} | head -120;
}
_ctx_last_resort(){ local cap="$1" f="${2:-}" msg x;
msg="[Earlier context was compacted locally due to size.${f:+ Focus: $f.} Continue from the latest user request.]";
x='[{"role":"user","content":"'$(json_escape "$msg")'"}]';
[ ${#x} -le "$cap" ] && printf '%s' "$x" || printf '[]';
}
_ctx_tail_start(){ printf '%s\n' "$1" | awk -v k="$2" '{a[NR]=$0;l[NR]=length($0)}END{s=0;for(i=NR;i>1;i--){s+=l[i];if(s>k)break}print i+1}';
}
_ctx_adjust_start(){ local o="$1" n="$2" c="$3" h guard=0;
while :;
do h=$(printf '%s\n' "$o" | sed -n "${c}p");
case "$h" in *reasoning*) break;;
 *tool_result*|*function_call_output*|*'"type":"function_call"'*) c=$((c-1));;
 *) break;;
 esac;
guard=$((guard+1));
[ "$c" -le 2 ] || [ "$guard" -gt 20 ] && break;
done;
[ "$c" -lt 2 ] && c=$((n-2));
printf '%s' "$c";
}
_ctx_sanitize_openai(){ local m="$1" cap="$2" o f new;
[ "$PROVIDER" = openai ] || { printf '%s' "$m";
return;
};
case "$m" in *'"type":"function_call_output"'*|*'"type"'*'"function_call_output"'*) ;;
 *) printf '%s' "$m";
return;;
 esac
  o=$(_ctx_entries "$m");
f=$(_ctx_filter_openai_pairs "$o");
[ "$f" = "$o" ] && { printf '%s' "$m";
return;
}
  new=$(printf '[%s]' "$(printf '%s\n' "$f" | tr '\n' ',' | sed 's/,$//')");
if _ctx_valid "$new" "$cap";
then log 0 compact "old=${#m} new=${#new} cap=$cap mode=sanitize-openai-pairs";
printf '%s' "$new";
else printf '%s' "$m";
fi;
}

# Context management: shrink long conversations before they exceed model windows.
trim_context(){ local m="$1" f="${2:-}" cap=$((CTX_LIMIT-AGENT_RESERVE)) o n c a r mid p req res s new kb=$AGENT_KEEP_RECENT half mode localnote compaction_summary_text
  [ -z "$f" ] && [ ${#m} -le "$cap" ] && { _ctx_sanitize_openai "$m" "$cap";
return;
}
  info "Compacting (${#m}b > ${cap}b)${f:+ focus: $f}"
  o=$(_ctx_entries "$m");
[ "$PROVIDER" = openai ] && o=$(_ctx_filter_openai_pairs "$o")
  n=$(printf '%s\n' "$o" | wc -l | tr -d ' ');
[ "$n" -lt 6 ] && { [ ${#m} -le "$cap" ] && printf '%s' "$m" || _ctx_last_resort "$cap" "$f";
return;
}
  half=$((cap/2));
[ "$kb" -gt "$half" ] && kb=$half;
[ "$kb" -lt 2000 ] && kb=2000
  c=$(_ctx_tail_start "$o" "$kb");
c=$(_ctx_adjust_start "$o" "$n" "$c")
  a=$(printf '%s\n' "$o" | sed -n 1p)
  mid=$(printf '%s\n' "$o" | sed -n "2,$((c-1))p" | awk '{if(length($0)>4000)print "[large transcript entry omitted: "length($0)" chars]";else print}' | tail -160)
  [ -z "$mid" ] && mid="[older transcript omitted]"
  p="${f:+Focus: $f. }Summarize the earlier transcript into this exact compact memory card. Be concise. Preserve actionable coding-agent state: user intent, constraints, files touched, edits, errors, decisions, and next steps. Prefer paths/ranges over copied bulk. Do not call tools.\n\nGoal:\nUser constraints/directives:\nFiles read:\nFiles changed:\nCommands run:\nErrors/failures:\nDecisions made:\nImportant snippets/facts:\nOpen TODOs / next steps:\n\nTranscript/facts:\n$mid"
  req='[{"role":"user","content":"'$(json_escape "$p")'"}]'
  res=$(call_api "$req");
parse_response "$res"
compaction_summary_text=$TX
  if [ -z "$compaction_summary_text" ];
then err "Summarization failed; using local compaction memory";
compaction_summary_text=$(_ctx_local_memory "$mid" "$f");
mode=local;
else mode=normal;
fi
  if [ "$mode" = local ];
then s='{"role":"user","content":"[Earlier compacted locally:\n'$(json_escape "$compaction_summary_text")']"}';
else s='{"role":"user","content":"[Earlier compacted memory:\n'$(json_escape "$compaction_summary_text")']"}';
fi
  while :;
do
    c=$(_ctx_tail_start "$o" "$kb");
c=$(_ctx_adjust_start "$o" "$n" "$c")
    r=$(printf '%s\n' "$o" | sed -n "${c},${n}p" | tr '\n' ',' | sed 's/,$//')
    new=$(printf '[%s,%s,%s]' "$a" "$s" "$r");
if _ctx_valid "$new" "$cap";
then log 0 compact "old=${#m} new=${#new} cap=$cap mode=$mode tail=$kb";
printf '%s' "$new";
return;
fi
    [ "$kb" -le 2000 ] && break;
kb=$((kb/2));
[ "$kb" -lt 2000 ] && kb=2000
  done
  if [ "$mode" = local ];
then localnote=$(printf '%s\n' "$o" | sed -n "2,${n}p" | awk '{if(length($0)>4000)print "[large transcript entry omitted: "length($0)" chars]";else print}' | tail -160);
compaction_summary_text=$(_ctx_local_memory "$localnote" "$f");
s='{"role":"user","content":"[Earlier compacted locally:\n'$(json_escape "$compaction_summary_text")']"}';
fi
  new=$(printf '[%s,%s]' "$a" "$s");
if _ctx_valid "$new" "$cap";
then log 0 compact "old=${#m} new=${#new} cap=$cap mode=${mode}-no-tail";
printf '%s' "$new";
return;
fi
  localnote=$(printf '%s\n' "$o" | sed -n "2,${n}p" | awk '{if(length($0)>4000)print "[large transcript entry omitted: "length($0)" chars]";else print}' | tail -160);
localnote=$(_ctx_local_memory "$localnote" "$f");
s='{"role":"user","content":"[Earlier compacted locally:\n'$(json_escape "$localnote")']"}'
  new=$(printf '[%s]' "$s");
if _ctx_valid "$new" "$cap";
then log 0 compact "old=${#m} new=${#new} cap=$cap mode=emergency";
printf '%s' "$new";
return;
fi
  new=$(_ctx_last_resort "$cap" "$f");
log 0 compact "old=${#m} new=${#new} cap=$cap mode=last-resort";
printf '%s' "$new";
}

# Project memory: include selected local documentation files as initial context.
load_context(){ local dir ctx f;
dir=$(pwd);
ctx="";
while [ "$dir" != "/" ];
do for f in AGENTS.md CLAUDE.md;
do [ -f "$dir/$f" ] && ctx="$ctx
$(cat "$dir/$f")" || true;
done;
dir=$(dirname "$dir");
done;
[ -f "$HOME/.pi/agent/AGENTS.md" ] && ctx="$(cat "$HOME/.pi/agent/AGENTS.md")
$ctx" || true;
[ -n "$ctx" ] && { info "Loaded context files";
SYSTEM="$SYSTEM
$ctx";
} || true;
}

# run_task
# -------------
# The central agent loop.
#
# The loop is deliberately simple:
#
#   1. Add the user's task to MSGS.
#   2. Compact history if it is near the context limit.
#   3. Send the current messages to the provider with call_api.
#   4. Parse the provider response with parse_response.
#   5. If the response is final text, print it, save it, and stop.
#   6. If the response is a tool request, run_tool executes it.
#   7. Append the tool result back into MSGS.
#   8. Repeat until final text or MAX_STEPS is reached.
#
# Important invariant:
#   Provider-native tool-call blocks and local tool-result blocks must be kept in
#   valid pairs. This is especially important for OpenAI Responses, where a
#   function_call_output must correspond to a previous function_call.
run_task(){ _STATE=busy;
local task="$1"
  case "$task" in '!'*) local r;
"$RUNSH" -c "${task#!}" 2>&1 & _CHILD=$!;
wait "$_CHILD" || r=$?;
_CHILD=0;
[ "$_STATE" = idle ] && return 130;
return "${r:-0}";;
 esac
  _ensure_key || return 1
  local task_esc;
task_esc=$(json_escape "$task")
  [ -z "$MSGS" ] && load || true
  [ -n "$MSGS" ] && [ "$MSGS" != "" ] && append "{\"role\":\"user\",\"content\":\"$task_esc\"}" || MSGS="[{\"role\":\"user\",\"content\":\"$task_esc\"}]"
  log 0 start "$task"
  local step=0 empty_final=0 ctx_retry=0
  while [ "$step" -lt "$MAX_STEPS" ];
do step=$((step+1))
    # Phase 1: keep the transcript small enough for the selected model.
    MSGS=$(trim_context "$MSGS")
    _STATE=busy
    local resp="" retry=0;
while [ $retry -lt 3 ];
do
      local rf cr=0;
rf=$(mktemp);
spin_start "$(_status)";
# Phase 2: send the full current transcript to the LLM provider.
call_api "$MSGS" >"$rf" 2>&1 & _CHILD=$!;
wait "$_CHILD" || cr=$?;
_CHILD=0;
resp=$(cat "$rf");
rm -f "$rf";
spin_stop;
[ -n "${AGENT_DEBUG_API:-}" ] && mkdir -p "$AGENT_DEBUG_API" 2>/dev/null && { printf '%s' "$MSGS" > "$AGENT_DEBUG_API/input-$step-$retry.json";
printf '%s' "$resp" > "$AGENT_DEBUG_API/resp-$step-$retry.json";
}
      [ "$_STATE" = idle ] && { err "[interrupted]";
return 130;
}
      [ $cr -ne 0 ] && { retry=$((retry+1));
err "API transport: $(printf '%s' "$resp" | head -1)";
[ $retry -ge 3 ] && return 1;
sleep $((retry*2));
continue;
}
      [ -z "$resp" ] && { retry=$((retry+1));
err "Empty, retry $retry/3";
sleep $((retry*2));
continue;
}
      local api_err em;
api_err=$(jp "$resp" error);
em=$(jp "$api_err" message)
      case "$(printf '%s' "$em" | tr A-Z a-z)" in *incorrect*api*key*|*invalid*api*key*|*unauthorized*|*authentication*) err "API: $em";
return 1;;
 *invalid*body*|*parse*json*) err "API: $em";
return 1;;
 *model*not*found*|*model*does*not*exist*|*model*not*exist*|*access*model*) err "API: $em";
err "Try /model MODEL";
return 1;;
 *context*|*token*limit*|*too*large*) [ "$ctx_retry" = 0 ] && { ctx_retry=1;
err "Context full; compacting and retrying";
MSGS=$(trim_context "$MSGS" "recover from context overflow");
continue;
};;
 esac
      [ -n "$api_err" ] && [ "$api_err" != "null" ] && [ "$api_err" != "" ] && { err "API: $em";
retry=$((retry+1));
sleep $((retry*3));
continue;
}
      break;
done
    [ -z "$resp" ] && { err "API failed";
log "$step" error "fail";
return 1;
}
    local fatal;
fatal=$(jp "$resp" error);
[ -n "$fatal" ] && [ "$fatal" != null ] && { err "API failed: $(jp "$fatal" message)";
log "$step" error "api";
return 1;
}
    track_tokens "$resp"
    # Phase 3: normalize provider-specific JSON into common parse variables.
    parse_response "$resp"
    if [ "$TY" = "T" ] && [ -n "$TN" ];
then
      [ -n "$TX" ] && [ "$TX" != null ] && _say "$TX"
      local trs="" trm="" trc="" _tu _tn _ti _tinp _tout _tesc _fn _src _mark
      case "$PROVIDER" in anthropic) _src="$CB";
_mark='"type":"tool_use"';;
 openai) _src="$TC";
_mark='"function_call"';;
 esac
      _src=$(printf '%s' "$_src" | tr -d '\n')
      while IFS= read -r _tu;
do
        [ -z "$_tu" ] && continue
        case "$PROVIDER" in
          anthropic) _tn=$(jp "$_tu" name);
_ti=$(jp "$_tu" id);
_tinp=$(jp "$_tu" input);;

          openai) [ "$(jp "$_tu" type)" = reasoning ] && { trc="${trc}${trc:+,}${_tu}";
continue;
};
_ti=$(jp "$_tu" call_id);
[ -z "$_ti" ] && _ti=$(jp "$_tu" id);
_tn=$(jp "$_tu" name);
_tinp=$(jp "$_tu" arguments);;

        esac
        { [ -z "$_ti" ] || [ -z "$_tn" ];
} && { log "$step" error "Bad tool call: $_tu";
continue;
}
        [ "$PROVIDER" = openai ] && trc="${trc}${trc:+,}${_tu}"
        log "$step" tool_call "$_tn: $(printf '%s' "$_tinp" | head -c 200)"
        local of;
of=$(mktemp);
spin_start;
# Phase 4: execute exactly the requested local tool and capture its output.
run_tool "$_tn" "$_tinp" >"$of" & _CHILD=$!;
wait "$_CHILD" || true;
_CHILD=0;
_tout=$(cat "$of");
rm -f "$of";
spin_stop
        [ "$_STATE" = idle ] && { err "[interrupted]";
return 130;
}
        log "$step" tool_result "$_tout";
case "$_tout" in Error:*|\[exit:*|\[denied*) [ "$PIPE" = 0 ] && err "$_tout";;
 esac;
_tesc=$(json_escape "$_tout")
        trs="${trs}${trs:+,}{\"type\":\"tool_result\",\"tool_use_id\":\"${_ti}\",\"content\":\"${_tesc}\"}"
        [ "$PROVIDER" = openai ] && trm="${trm},{\"type\":\"function_call_output\",\"call_id\":\"${_ti}\",\"output\":\"${_tesc}\"}" || trm="${trm},{$RT,\"tool_call_id\":\"${_ti}\",\"content\":\"${_tesc}\"}"
      done <<EOF
$([ "$PROVIDER" = openai ] && oa_items "$_src" || each_tool_use "$_src" "$_mark")
EOF
      [ -z "$trs" ] && { err "No valid tool calls parsed";
dbg "$resp";
log "$step" error "No valid tool calls parsed";
return 1;
}
      case "$PROVIDER" in
        anthropic) [ -n "$CB" ] && append "{$RA,\"content\":${CB}},{$RU,\"content\":[$trs]}" || {
          local _ti0;
_ti0="$TINP";
[ -z "$_ti0" ] && _ti0="{}"
          append "{$RA,\"content\":[{\"type\":\"text\",\"text\":\"\"},{\"type\":\"tool_use\",\"id\":\"${TI}\",\"name\":\"${TN}\",\"input\":${_ti0}}]},{$RU,\"content\":[$trs]}"
        };;

        openai) append "${trc}${trm}";;

      esac;
save
    elif [ "$TY" = "X" ];
then
      # Phase 5: final assistant text means the task is complete.
      if [ -z "$TX" ] || [ "$TX" = null ];
then [ "$empty_final" = 0 ] && { empty_final=1;
[ "$PROVIDER:$EFFORT_OK" = openai:1 ] && EFFORT=low;
append '{"role":"user","content":"Please summarize your findings and next steps."}';
continue;
};
err "Empty final response";
return 1;
fi
      [ "$PIPE" = 0 ] && [ "$INTERACTIVE" = 1 ] && _say "$TX" || printf '%s\n' "$TX"
      log "$step" response "$TX";
append "{\"role\":\"assistant\",\"content\":\"$(json_escape "$TX")\"}"
      info "done · $(_status)"
      save;
return 0
    else err "Parse failed";
dbg "$resp";
log "$step" error "Parse fail";
return 1;
fi
  done;
err "Max steps ($MAX_STEPS)"
  info "stopped · $(_status)"
  log "$step" max_steps "Limit";
return 1;
}

# Optional prompt snippets: load reusable templates or skill files from disk.
_tpl(){ for d in .pi/prompts "$HOME/.pi/agent/prompts";
do [ -f "$d/$1.md" ] && { cat "$d/$1.md";
return;
};
done;
echo "$1";
}
_skill(){ for d in .pi/skills .agents/skills "$HOME/.pi/agent/skills" "$HOME/.agents/skills";
do [ -f "$d/$1/SKILL.md" ] && { info "Loaded skill: $1";
SYSTEM="$SYSTEM
$(cat "$d/$1/SKILL.md")";
return;
};
done;
err "Skill not found: $1";
}

# Markdown export: turn the latest event log session into a readable report.
_export(){ local out="${1:-session.md}";
printf '# Session Export\n\n' > "$out";
[ -f "$LOG" ] && while IFS= read -r line;
do local t;
t=$(jp "$line" t);
local c;
c=$(jp "$line" c);
case "$t" in start) printf '## Task\n%s\n\n' "$c";;
 tool_call) printf '### Tool: %s\n' "$c";;
 tool_result) printf '```\n%s\n```\n\n' "$c";;
 response) printf '## Response\n%s\n\n' "$c";;
 esac;
done < "$LOG" >> "$out";
info "Exported to $out";
}
_sq(){ printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")";
}

# Authentication helpers: discover, prompt for, and persist provider API keys.
_have_key(){ case "$PROVIDER" in anthropic) [ -n "${ANTHROPIC_API_KEY:-}" ];;
 openai) [ -n "${OPENAI_API_KEY:-}" ];;
 *) return 2;;
 esac;
}
_ensure_key(){ _have_key || { [ -t 0 ] && _setup || { err "No API key. Set ANTHROPIC_API_KEY or OPENAI_API_KEY (https://console.anthropic.com/settings/keys | https://platform.openai.com/api-keys)";
return 1;
};
};
}

# Provider setup: choose a provider/model pair and write it to .env.
_set_provider_model(){ PROVIDER="$1";
MODEL="$2";
EFFORT_OK=0;
case "$PROVIDER:$MODEL" in openai:gpt-5.5*) [ -z "${AGENT_CONTEXT_LIMIT:-}" ] && CTX_LIMIT=400000; EFFORT_OK=1;; anthropic:claude-opus-4-7*) [ -z "${AGENT_CONTEXT_LIMIT:-}" ] && CTX_LIMIT=272000; EFFORT_OK=1;; anthropic:claude-opus-4-6*|anthropic:claude-sonnet-4-6*|anthropic:claude-opus-4-5*) EFFORT_OK=1;; esac;
}

# Interactive setup: guide a new user through provider and API-key configuration.
_setup(){ local p k m e s u km dm os
  printf '\nWelcome to pu-unminified.sh.\n\nProvider:\n  1) Anthropic (Claude)\n  2) OpenAI (GPT)\n> ' >&2;
read -r p
  case "$p" in 2|openai|OpenAI) PROVIDER=openai;
km=OPENAI_API_KEY;
u=https://platform.openai.com/api-keys;
dm=gpt-5.5;;
 *) PROVIDER=anthropic;
km=ANTHROPIC_API_KEY;
u=https://console.anthropic.com/settings/keys;
dm=claude-opus-4-7;;
 esac
  command -v open >/dev/null 2>&1 && open "$u" 2>/dev/null || command -v xdg-open >/dev/null 2>&1 && xdg-open "$u" 2>/dev/null || true
  printf 'Get a key at %s\nPaste API key (hidden): ' "$u" >&2;
os=$(stty -g 2>/dev/null || true);
stty -echo 2>/dev/null || true;
read -r k;
[ -n "$os" ] && stty "$os" 2>/dev/null || stty echo 2>/dev/null;
printf '\n' >&2
  k=$(_clean_key "$k")
  [ -z "$k" ] && { err "No key entered";
exit 1;
};
printf 'Model [%s]: ' "$dm" >&2;
read -r m;
[ -z "$m" ] && m=$dm;
_set_provider_model "$PROVIDER" "$m"
  printf 'Effort [medium] (OpenAI: none/minimal/low/medium/high/xhigh; Claude: low/medium/high/max, xhigh on Opus 4.7): ' >&2;
read -r e;
[ -z "$e" ] && e=medium;
case "$e" in n) e=none;;
 min) e=minimal;;
 l) e=low;;
 m) e=medium;;
 h) e=high;;
 x|xh) e=xhigh;;
 esac;
EFFORT=$e;
export "$km=$k" AGENT_PROVIDER="$PROVIDER" AGENT_MODEL="$MODEL" AGENT_EFFORT="$EFFORT"
  printf 'Save to ~/.pu.env so next time is automatic? [Y/n] ' >&2;
read -r s;
case "$s" in n|N|no|NO) info "Not saved (set in this session only)";;
 *) (umask 077;
printf '%s=%s\nAGENT_PROVIDER=%s\nAGENT_MODEL=%s\nAGENT_EFFORT=%s\n' "$km" "$(_sq "$k")" "$(_sq "$PROVIDER")" "$(_sq "$MODEL")" "$(_sq "$EFFORT")" > "$HOME/.pu.env") && info "Saved ~/.pu.env";;
 esac;
}

# Slash commands: in-session commands such as /compact, /context, /exit.
# These commands are handled locally and never sent to the model as user tasks.
handle_cmd(){ case "$1" in
  /model|/model\ *) local nm;
nm=$(printf '%s' "$1" | sed 's|^/model *||')
    [ -n "$nm" ] && { case "$nm" in gpt-*|o1*|o3*|o4*) _set_provider_model openai "$nm";;
 claude-*) _set_provider_model anthropic "$nm";;
 *) MODEL="$nm";;
 esac;
info "Model: $MODEL ($PROVIDER)";
} || info "Current: $MODEL ($PROVIDER)";
return 0;;

  /effort|/effort\ *) local ef;
ef=$(printf '%s' "$1" | sed 's|^/effort *||');
[ -n "$ef" ] && { case "$ef" in n) ef=none;;
 min) ef=minimal;;
 l) ef=low;;
 m) ef=medium;;
 h) ef=high;;
 x|xh) ef=xhigh;;
 esac;
EFFORT=$ef;
};
info "Effort: $EFFORT";
return 0;;
 /flush) MSGS="";
[ -n "$HISTORY" ] && printf '[]' > "$HISTORY";
info "Flushed conversation memory";
return 0;;
 /quit|/exit) exit 0;;

  /login) _setup;
return 0;;
 /logout) [ -f "$HOME/.pu.env" ] && rm "$HOME/.pu.env" && info "Removed ~/.pu.env" || info "No ~/.pu.env to remove";
unset ANTHROPIC_API_KEY OPENAI_API_KEY;
info "Logged out. /login or set env vars to continue.";
return 0;;

  /compact|/compact\ *) MSGS=$(trim_context "$MSGS" "$(printf '%s' "$1" | sed 's|^/compact *||')");
save;
info "Compacted (${#MSGS}b)";
return 0;;

  /export|/export\ *) _export "$(printf '%s' "$1" | sed 's|^/export *||')";
return 0;;

  /skill:*) _skill "$(printf '%s' "$1" | sed 's|^/skill:||')";
return 0;;

  /session) info "Log: $LOG | Model: $MODEL ($PROVIDER) | Max steps: $MAX_STEPS";
return 0;;

  /*) local cn;
cn=$(printf '%s' "$1" | sed 's|^/||' | cut -d' ' -f1);
local tp;
tp=$(_tpl "$cn");
[ "$tp" != "$cn" ] && { info "Template: $cn";
run_task "$tp";
return 0;
}
    err "Unknown command: $1";
return 0;;

  esac;
return 1;
}
TASK="";
if [ "$PIPE" = 1 ] && [ ! -t 0 ];
then IN=$(cat);
[ $# -gt 0 ] && TASK=$([ -n "$IN" ] && printf '%s\n%s' "$IN" "$*" || printf '%s' "$*") || TASK="$IN";
else [ $# -gt 0 ] && TASK="$*" || { [ ! -t 0 ] && TASK=$(cat);
};
fi
[ -z "$TASK" ] && [ -t 0 ] && [ "$INTERACTIVE" != -1 ] && INTERACTIVE=1
[ -z "$TASK" ] && [ "$INTERACTIVE" != 1 ] && { err "No task. Usage: ./pu-unminified.sh \"task\" or ./pu-unminified.sh -i";
exit 1;
}
_ensure_key || exit 1;
load_context
[ -z "$MSGS" ] && load && { _replay;
info "Resumed memory: $HISTORY (/flush to clear)";
} || true;
[ -n "$TASK" ] && { info "$TASK";
info "$MODEL ($PROVIDER) max steps: $MAX_STEPS";
run_task "$TASK";
rc=$?;
[ "$INTERACTIVE" = 1 ] || exit "$rc";
} || true
info "$MODEL ($PROVIDER) | /model /effort /login /logout /flush /compact /export /skill:name /quit | !cmd";
while true;
do _STATE=idle;
printf '\033[36m> \033[0m' >&2;
read -r INPUT || break;
case "$INPUT" in quit|exit|q) break;;
 ''|' ') continue;;
 esac;
handle_cmd "$INPUT" && continue || true;
run_task "$INPUT";
done