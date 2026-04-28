#!/bin/sh
# pu.sh — portable agentic harness. sh + curl. Zero dependencies beyond POSIX.
# Usage: ./pu.sh "task" | ./pu.sh (interactive) | ./pu.sh --pipe "review"
set -u
_STATE=idle _CHILD=0 SPIN_PID=""
_spinner(){ tput civis 2>/dev/null; while :;do
  for f in '[   ]' '[=  ]' '[== ]' '[===]' '[ ==]' '[  =]';do printf '\r\033[K%s' "$f" >&2;sleep 0.15;done;done;}
spin_start(){ [ -t 2 ]||return 0;[ -n "$SPIN_PID" ]&&return 0;_spinner& SPIN_PID=$!;}
spin_stop(){ [ -n "$SPIN_PID" ]&&{ kill "$SPIN_PID" 2>/dev/null;wait "$SPIN_PID" 2>/dev/null;SPIN_PID="";};printf '\r\033[K' >&2;tput cnorm 2>/dev/null||true;}
_interrupt(){ spin_stop; if [ "$_STATE" = busy ]; then
  [ $_CHILD -ne 0 ] && kill $_CHILD 2>/dev/null && wait $_CHILD 2>/dev/null; _CHILD=0
  _STATE=idle
  else exit 130; fi;}
trap '_interrupt' INT; trap '' PIPE
MODEL="${AGENT_MODEL:-claude-sonnet-4-20250514}" PROVIDER="${AGENT_PROVIDER:-anthropic}"
MAX_STEPS="${AGENT_MAX_STEPS:-25}" MAX_TOKENS="${AGENT_MAX_TOKENS:-4096}"
LOG="${AGENT_LOG:-agent.jsonl}" HISTORY="${AGENT_HISTORY:-}" CONFIRM="${AGENT_CONFIRM:-0}"
CTX_LIMIT="${AGENT_CONTEXT_LIMIT:-100000}" VERBOSE="${AGENT_VERBOSE:-0}" THINKING="${AGENT_THINKING:-}"
PIPE=0 COST=0 INTERACTIVE=0
SYSTEM="${AGENT_SYSTEM:-You are an expert coding assistant. You help users by reading files, executing commands, editing code, and writing new files.
Available tools:
- read: Read file contents. Use offset/limit for large files.
- bash: Execute bash commands (ls, grep, find, etc.)
- edit: Make precise file edits with exact text replacement via oldText/newText
- write: Create or overwrite files. Automatically creates parent directories.
- grep: Search file contents for patterns
- find: Find files by glob pattern
- ls: List directory contents
Guidelines:
- Use read to examine files instead of cat or sed.
- Use write only for new files or complete rewrites. Never use bash with cat/heredoc/echo to create files.
- Use edit for precise changes (oldText must match exactly). Keep oldText as small as possible while still unique.
- Be concise in your responses.
- Show file paths clearly when working with files.
Current date: $(date +%Y-%m-%d)
Current working directory: $(pwd)
Your source code is at $(cd "$(dirname "$0")" && pwd)/$(basename "$0"). Use the read tool to inspect it if asked about your own capabilities or configuration.}"
case "${1:-}" in -h|--help) cat<<'HELP'
pu.sh — portable agentic harness (sh+curl, no deps)
Usage: ./pu.sh "task" | ./pu.sh (interactive) | --pipe | --cost | -v
Env: ANTHROPIC_API_KEY OPENAI_API_KEY AGENT_MODEL AGENT_PROVIDER AGENT_SYSTEM
 AGENT_MAX_STEPS AGENT_MAX_TOKENS AGENT_LOG AGENT_CONFIRM AGENT_VERBOSE
 AGENT_CONTEXT_LIMIT AGENT_RESERVE AGENT_TOOL_TRUNC
 AGENT_HISTORY(checkpoint) AGENT_THINKING(off/low/medium/high)
7 tools, multi-turn, retries, JSONL logging, pipe mode, @file refs, !command
Auto-compaction (Pi-style): summarizes older turns when context fills.
/compact [focus] manually triggers it.
HELP
exit 0;;-v|--version)echo "pu.sh 1.0.0";exit 0;;--pipe|-p)PIPE=1;shift;;--cost)COST=1;shift;;-i)INTERACTIVE=1;shift;;-n|--no-interactive)INTERACTIVE=-1;shift;;esac
for _dep in curl awk;do command -v $_dep >/dev/null 2>&1||{ printf '\033[31m[!] %s not found\033[0m\n' "$_dep" >&2;exit 1;};done
jp(){
  printf '%s' "$1" | awk -v k="$2" 'BEGIN{RS="\0"}{
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
      gsub(/\\n/,"\n",o); gsub(/\\t/,"\t",o); gsub(/\\\\/,"\\",o); gsub(/\\"/,"\"",o)
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
  printf '%s' "$1" | awk -v t="$2" 'BEGIN{RS="\0"}{
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
j1st(){
  printf '%s' "$1" | awk 'BEGIN{RS="\0"}{
    n=index($0,"{"); d=0; o=""; q=0; e=0
    for(i=n;i<=length($0);i++){
      c=substr($0,i,1); o=o c
      if(e){e=0;continue}; if(c=="\\"){e=1;continue}
      if(c=="\""){q=!q;continue}; if(q)continue
      if(c=="{")d++; else if(c=="}")d--
      if(d==0)break
    }; print o
  }'
}
json_escape(){ printf '%s' "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037' | awk '{gsub(/\\/,"\\\\")} {gsub(/"/,"\\\"")} {gsub(/\t/,"\\t")} {gsub(/\r/,"\\r")} NR>1{printf "\\n"} {printf "%s",$0}';}
info(){ [ "$PIPE" = 0 ] && printf '\033[36m[pu]\033[0m %s\n' "$*" >&2 || true;}
err(){ printf '\033[31m[!] %s\033[0m\n' "$*" >&2;}
dbg(){ [ "$VERBOSE" = 1 ] && printf '[v] %s\n' "$*" >&2 || true;}
log(){ printf '{"s":%s,"t":"%s","c":"%s"}\n' "$1" "$2" "$(json_escape "$3")" >> "$LOG";}
SP='{"type":"object","properties":{"command":{"type":"string","description":"Shell command"}},"required":["command"]}'
RP='{"type":"object","properties":{"path":{"type":"string"},"offset":{"type":"integer","description":"Start line"},"limit":{"type":"integer","description":"Max lines"}},"required":["path"]}'
WP='{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}'
EP='{"type":"object","properties":{"path":{"type":"string"},"oldText":{"type":"string","description":"Exact text to find"},"newText":{"type":"string","description":"Replacement"}},"required":["path","oldText","newText"]}'
GP='{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"}},"required":["pattern"]}'
FP='{"type":"object","properties":{"path":{"type":"string"},"name":{"type":"string","description":"Glob"}},"required":["path"]}'
LP='{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}'
TD='{"name":"bash","description":"Run a shell command","input_schema":'$SP'},{"name":"read","description":"Read file contents","input_schema":'$RP'},{"name":"write","description":"Write content to file, creates dirs","input_schema":'$WP'},{"name":"edit","description":"Edit file with exact text replacement","input_schema":'$EP'},{"name":"grep","description":"Search for pattern in files","input_schema":'$GP'},{"name":"find","description":"Find files by name glob","input_schema":'$FP'},{"name":"ls","description":"List directory","input_schema":'$LP'}'
TF='{"type":"function","function":{"name":"bash","description":"Run a shell command","parameters":'$SP'}},{"type":"function","function":{"name":"read","description":"Read file contents","parameters":'$RP'}},{"type":"function","function":{"name":"write","description":"Write content to file","parameters":'$WP'}},{"type":"function","function":{"name":"edit","description":"Edit file with exact text replacement","parameters":'$EP'}},{"type":"function","function":{"name":"grep","description":"Search for pattern","parameters":'$GP'}},{"type":"function","function":{"name":"find","description":"Find files","parameters":'$FP'}},{"type":"function","function":{"name":"ls","description":"List directory","parameters":'$LP'}}'
think_param(){ case "$THINKING" in low) echo ',"thinking":{"type":"enabled","budget_tokens":1024}';;medium) echo ',"thinking":{"type":"enabled","budget_tokens":4096}';;high|xhigh) echo ',"thinking":{"type":"enabled","budget_tokens":10000}';;*) echo '';;esac;}
call_api(){ local sys_esc; sys_esc=$(json_escape "$SYSTEM"); local tp; tp=$(think_param)
  case "$PROVIDER" in
  anthropic) curl -sS -m120 \
    -H "x-api-key:${ANTHROPIC_API_KEY:-}" \
    -H anthropic-version:2023-06-01 \
    -H content-type:application/json \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":$MAX_TOKENS,\"system\":\"$sys_esc\",\"tools\":[$TD],\"messages\":$1${tp}}" \
    https://api.anthropic.com/v1/messages 2>&1;;
  openai) curl -sS -m120 \
    -H "Authorization:Bearer ${OPENAI_API_KEY:-}" \
    -H content-type:application/json \
    -d "{\"model\":\"$MODEL\",\"max_tokens\":$MAX_TOKENS,\"messages\":[{\"role\":\"system\",\"content\":\"$sys_esc\"},$1],\"tools\":[$TF]}" \
    https://api.openai.com/v1/chat/completions 2>&1;;
  esac;}
parse_response(){ local resp="$1"; TY= TN= TI= TX= CB= TINP=
  if [ "$PROVIDER" = anthropic ]; then
    local tu; tu=$(jb "$resp" "tool_use")
    if [ -n "$tu" ]; then
      TY=T; TN=$(jp "$tu" name); TI=$(jp "$tu" id); TINP=$(jp "$tu" input)
      local tt; tt=$(jb "$resp" "text"); TX=$(jp "$tt" text)
      CB=$(jp "$resp" content)
    else
      TY=X; local tt; tt=$(jb "$resp" "text"); TX=$(jp "$tt" text)
    fi
  else
    local msg; msg=$(j1st "$(jp "$resp" choices)")
    msg=$(jp "$msg" message)
    local tc; tc=$(jp "$msg" tool_calls)
    if [ -n "$tc" ] && [ "$tc" != "null" ]; then
      TY=T; local call; call=$(j1st "$tc")
      TI=$(jp "$call" id)
      local fn; fn=$(jp "$call" function)
      TN=$(jp "$fn" name); TINP=$(jp "$fn" arguments)
      TX=$(jp "$msg" content)
    else
      TY=X; TX=$(jp "$msg" content)
    fi
  fi;}
run_tool(){ local tool_name="$1" input="$2"
  [ "$CONFIRM" = 1 ] && {
    printf '\033[33m[?] %s: %s\033[0m [y/N] ' "$tool_name" "$(printf '%s' "$input" | head -c 80)" >&2
    read -r yn; [ "$yn" = y ] || [ "$yn" = Y ] || { echo "[denied]"; return 0; }
  }
  local out="" rc=0
  case "$tool_name" in
    bash)
      local cmd; cmd=$(jp "$input" command)
      info "\$ $cmd"
      local tf; tf=$(mktemp); printf '%s\n' "$cmd" > "$tf"
      out=$(sh "$tf" 2>&1) && rc=0 || rc=$?; rm -f "$tf"
      [ $rc -ne 0 ] && out="$out
[exit:$rc]";;
    read)
      local fp; fp=$(jp "$input" path)
      local off; off=$(jp "$input" offset)
      local lim; lim=$(jp "$input" limit)
      info "read: $fp"
      if [ -f "$fp" ]; then
        if [ -n "$off" ] && [ -n "$lim" ]; then out=$(sed -n "${off},$((off+lim-1))p" "$fp")
        elif [ -n "$off" ]; then out=$(sed -n "${off},\$p" "$fp")
        elif [ -n "$lim" ]; then out=$(head -n "$lim" "$fp")
        else out=$(cat "$fp"); fi
      else out="Error: file not found: $fp"; rc=1; fi;;
    write)
      local fp; fp=$(jp "$input" path)
      local ct; ct=$(jp "$input" content)
      info "write: $fp"
      mkdir -p "$(dirname "$fp")" 2>/dev/null
      printf '%s\n' "$ct" > "$fp" && out="Wrote to $fp" || { out="Error writing $fp"; rc=1; };;
    edit)
      local fp; fp=$(jp "$input" path)
      local old; old=$(jp "$input" oldText)
      local new; new=$(jp "$input" newText)
      info "edit: $fp"
      if [ -f "$fp" ]; then
        if grep -qF "$old" "$fp"; then
          awk -v o="$old" -v n="$new" 'BEGIN{RS="\0";ORS=""}{i=index($0,o);while(i>0){printf "%s%s",substr($0,1,i-1),n;$0=substr($0,i+length(o));i=index($0,o)}printf "%s",$0}' "$fp" > "$fp.tmp" && mv "$fp.tmp" "$fp"
          out="Edited $fp"
        else out="Error: oldText not found in $fp"; rc=1; fi
      else out="Error: file not found: $fp"; rc=1; fi;;
    grep)
      local pat; pat=$(jp "$input" pattern)
      local gp; gp=$(jp "$input" path); [ -z "$gp" ] && gp="."
      info "grep: $pat $gp"
      out=$(grep -rn "$pat" "$gp" 2>&1 | head -100) || rc=$?;;
    find)
      local fp; fp=$(jp "$input" path); [ -z "$fp" ] && fp="."
      local fn; fn=$(jp "$input" name)
      info "find: $fp $fn"
      [ -n "$fn" ] && out=$(find "$fp" -name "$fn" 2>&1 | head -100) || out=$(find "$fp" -maxdepth 3 2>&1 | head -100);;
    ls)
      local lp; lp=$(jp "$input" path); [ -z "$lp" ] && lp="."
      info "ls: $lp"; out=$(ls -la "$lp" 2>&1);;
    *)
      info "\$ $input"; out=$(sh -c "$input" 2>&1) && rc=0 || rc=$?;;
  esac
  M="${AGENT_TOOL_TRUNC:-2000}"; [ ${#out} -gt "$M" ] && out="$(printf '%s\n' "$out" | awk '{a[NR]=$0}END{if(NR<=40){for(i=1;i<=NR;i++)print a[i];exit}for(i=1;i<=30;i++)print a[i];printf "...[%d lines truncated]...\n",NR-40;for(i=NR-9;i<=NR;i++)print a[i]}')"
  printf '%s' "$out";}
MSGS=""
save(){ [ -n "$HISTORY" ] && printf '%s' "$MSGS" > "$HISTORY" || true;}
load(){ [ -n "$HISTORY" ] && [ -f "$HISTORY" ] && MSGS=$(cat "$HISTORY") && info "Resumed: $HISTORY" && return 0; return 1;}
append(){ MSGS=$(printf '%s' "$MSGS" | sed 's/]$//')",$1]";}
RA='"role":"assistant"' RU='"role":"user"' RT='"role":"tool"'
TOKEN_IN=0 TOKEN_OUT=0
track_tokens(){ [ "$COST" = 1 ] && { local u; u=$(jp "$1" usage); local a; a=$(jp "$u" input_tokens); local b; b=$(jp "$u" output_tokens); TOKEN_IN=$((TOKEN_IN+${a:-0})); TOKEN_OUT=$((TOKEN_OUT+${b:-0})); } || true;}
trim_context(){ local m="$1" f="${2:-}" cap=$((CTX_LIMIT-${AGENT_RESERVE:-16000})) o n c h a r mid p req res s
  [ -z "$f" ] && [ ${#m} -le "$cap" ] && { printf '%s' "$m"; return; }
  info "Compacting (${#m}b > ${cap}b)${f:+ focus: $f}"
  o=$(printf '%s' "$m" | awk 'BEGIN{RS="\0"}{d=0;q=0;e=0;for(i=1;i<=length($0);i++){c=substr($0,i,1)
    if(e){e=0;continue};if(c=="\\"){e=1;continue};if(c=="\""){q=!q;continue};if(q)continue
    if(c=="{"){if(d==0)s=i;d++}else if(c=="}"){d--;if(d==0)print substr($0,s,i-s+1)}}}')
  n=$(printf '%s\n' "$o" | wc -l | tr -d ' '); [ "$n" -lt 6 ] && { printf '%s' "$m"; return; }
  c=$((n-3)); h=$(printf '%s\n' "$o" | sed -n "${c}p")
  case "$h" in *tool_result*) c=$((c-1));; esac
  [ "$c" -lt 2 ] && { printf '%s' "$m"; return; }
  a=$(printf '%s\n' "$o" | sed -n 1p)
  r=$(printf '%s\n' "$o" | sed -n "${c},${n}p" | tr '\n' ',' | sed 's/,$//')
  mid=$(printf '%s\n' "$o" | sed -n "2,$((c-1))p")
  [ -z "$mid" ] && { printf '%s' "$m"; return; }
  p="${f:+Focus: $f. }Summarize this transcript in under 500 words, preserving files read, errors hit, code changes, decisions made. Do not call tools.

$mid"
  req='[{"role":"user","content":"'$(json_escape "$p")'"}]'
  res=$(call_api "$req"); parse_response "$res"
  [ -z "$TX" ] && { err "Summarization failed; passing through"; printf '%s' "$m"; return; }
  s='{"role":"user","content":"[Earlier compacted: '$(json_escape "$TX")']"}'
  printf '[%s,%s,%s]' "$a" "$s" "$r";}
load_context(){ local dir; dir=$(pwd); local ctx=""
  while [ "$dir" != "/" ]; do
    for f in AGENTS.md CLAUDE.md; do [ -f "$dir/$f" ] && ctx="$ctx
$(cat "$dir/$f")" || true; done; dir=$(dirname "$dir"); done
  [ -f "$HOME/.pi/agent/AGENTS.md" ] && ctx="$(cat "$HOME/.pi/agent/AGENTS.md")
$ctx" || true
  [ -n "$ctx" ] && { info "Loaded context files"; SYSTEM="$SYSTEM
$ctx"; } || true;}
expand_refs(){ local t="$1"
  case "$t" in *@*)
    local fp; fp=$(printf '%s' "$t" | grep -o '@[^ ]*' | head -1 | sed 's/^@//' 2>/dev/null) || true
    [ -n "$fp" ] && [ -f "$fp" ] && { local fc; fc=$(cat "$fp"); t=$(printf '%s' "$t" | sed "s|@$fp|[file: $fp]\n$fc|"); } || true;;
  esac
  printf '%s' "$t";}
run_task(){ _STATE=busy; local task="$1"; task=$(expand_refs "$task")
  case "$task" in '!'*) sh -c "$(printf '%s' "$task" | sed 's/^!//')" 2>&1; return;; esac
  local task_esc; task_esc=$(json_escape "$task")
  [ -n "$MSGS" ] && append "{\"role\":\"user\",\"content\":\"$task_esc\"}" || { load || MSGS="[{\"role\":\"user\",\"content\":\"$task_esc\"}]"; }
  log 0 start "$task"
  local step=0
  while [ "$step" -lt "$MAX_STEPS" ]; do step=$((step+1)); info "--- $step/$MAX_STEPS ---"
    MSGS=$(trim_context "$MSGS")
    _STATE=busy
    local resp="" retry=0; while [ $retry -lt 3 ]; do
      spin_start; resp=$(call_api "$MSGS") || true; spin_stop
      [ "$_STATE" = idle ] && { err "[interrupted]"; return 130; }
      [ -z "$resp" ] && { retry=$((retry+1)); err "Empty, retry $retry/3"; sleep $((retry*2)); continue; }
      local api_err; api_err=$(jp "$resp" error)
      [ -n "$api_err" ] && { err "API: $(jp "$api_err" message)"; retry=$((retry+1)); sleep $((retry*3)); continue; }
      break; done
    [ -z "$resp" ] && { err "API failed"; log "$step" error "fail"; exit 1; }
    track_tokens "$resp"
    parse_response "$resp"
    if [ "$TY" = "T" ] && [ -n "$TN" ]; then
      [ -n "$TX" ] && info "$TX" || true; log "$step" tool_call "$TN: $(printf '%s' "$TINP" | head -c 200)"
      spin_start; local tool_out; tool_out=$(run_tool "$TN" "$TINP"); spin_stop
      [ "$_STATE" = idle ] && { err "[interrupted]"; return 130; }
      log "$step" tool_result "$tool_out"
      local tool_esc; tool_esc=$(json_escape "$tool_out")
      local tr="{\"type\":\"tool_result\",\"tool_use_id\":\"${TI}\",\"content\":\"${tool_esc}\"}"
      case "$PROVIDER" in
        anthropic) [ -n "$CB" ] && append "{$RA,\"content\":${CB}},{$RU,\"content\":[$tr]}" || {
          local inp_esc; inp_esc=$(json_escape "$TINP")
          append "{$RA,\"content\":[{\"type\":\"text\",\"text\":\"\"},{\"type\":\"tool_use\",\"id\":\"${TI}\",\"name\":\"${TN}\",\"input\":${TINP:-{}}}]},{$RU,\"content\":[$tr]}"; };;
        openai) local inp_esc; inp_esc=$(json_escape "$TINP")
          append "{$RA,\"tool_calls\":[{\"id\":\"${TI}\",\"type\":\"function\",\"function\":{\"name\":\"${TN}\",\"arguments\":\"${inp_esc}\"}}]},{$RT,\"tool_call_id\":\"${TI}\",\"content\":\"${tool_esc}\"}";;
      esac; save
    elif [ "$TY" = "X" ]; then
      LAST_RESP="$TX"; [ "$PIPE" = 0 ] && info "Response:" || true; printf '%s\n' "$TX"
      log "$step" response "$TX"
      [ "$COST" = 1 ] && [ $TOKEN_IN -gt 0 ] && info "Tokens: $TOKEN_IN in + $TOKEN_OUT out" || true
      info "Done ($step steps)"; save; return 0
    else err "Parse failed"; dbg "$resp"; log "$step" error "Parse fail"; return 1; fi
  done; err "Max steps ($MAX_STEPS)"
  [ "$COST" = 1 ] && [ $TOKEN_IN -gt 0 ] && info "Tokens: $TOKEN_IN in + $TOKEN_OUT out" || true
  log "$step" max_steps "Limit"; return 1; }
_tpl(){ for d in .pi/prompts "$HOME/.pi/agent/prompts"; do [ -f "$d/$1.md" ] && { cat "$d/$1.md"; return; }; done; echo "$1";}
_skill(){ for d in .pi/skills .agents/skills "$HOME/.pi/agent/skills" "$HOME/.agents/skills"; do
  [ -f "$d/$1/SKILL.md" ] && { info "Loaded skill: $1"; SYSTEM="$SYSTEM
$(cat "$d/$1/SKILL.md")"; return; }; done; err "Skill not found: $1";}
LAST_RESP=""
_copy(){ [ -z "$LAST_RESP" ] && { err "Nothing to copy"; return; }
  if command -v pbcopy >/dev/null 2>&1; then printf '%s' "$LAST_RESP" | pbcopy
  elif command -v xclip >/dev/null 2>&1; then printf '%s' "$LAST_RESP" | xclip -sel clip
  else err "No clipboard (pbcopy/xclip)"; return; fi; info "Copied";}
_export(){ local out="${1:-session.md}"; printf '# Session Export\n\n' > "$out"
  [ -f "$LOG" ] && while IFS= read -r line; do local t; t=$(jp "$line" t); local c; c=$(jp "$line" c)
    case "$t" in start) printf '## Task\n%s\n\n' "$c";; tool_call) printf '### Tool: %s\n' "$c";;
      tool_result) printf '```\n%s\n```\n\n' "$c";; response) printf '## Response\n%s\n\n' "$c";; esac
  done < "$LOG" >> "$out"; info "Exported to $out";}
_fork(){ local nf="${LOG%.jsonl}_fork_$(date +%s).jsonl"
  [ -f "$LOG" ] && cp "$LOG" "$nf" && info "Forked to $nf" || err "Nothing to fork";}
handle_cmd(){ case "$1" in
  /model|/model\ *) local nm; nm=$(printf '%s' "$1" | sed 's|^/model *||')
    [ -n "$nm" ] && { MODEL="$nm"; info "Model: $MODEL"; } || info "Current: $MODEL"; return 0;;
  /copy) _copy; return 0;; /fork) _fork; return 0;; /quit|/exit) exit 0;;
  /compact|/compact\ *) MSGS=$(trim_context "$MSGS" "$(printf '%s' "$1" | sed 's|^/compact *||')"); save; info "Compacted (${#MSGS}b)"; return 0;;
  /export|/export\ *) _export "$(printf '%s' "$1" | sed 's|^/export *||')"; return 0;;
  /skill:*) _skill "$(printf '%s' "$1" | sed 's|^/skill:||')"; return 0;;
  /session) info "Log: $LOG | Model: $MODEL ($PROVIDER) | Steps: $MAX_STEPS"; return 0;;
  /*) local cn; cn=$(printf '%s' "$1" | sed 's|^/||' | cut -d' ' -f1); local tp; tp=$(_tpl "$cn")
    [ "$tp" != "$cn" ] && { info "Template: $cn"; run_task "$tp"; return 0; }
    err "Unknown command: $1"; return 0;;
  esac; return 1;}
TASK=""; [ $# -gt 0 ] && TASK="$*" || { [ ! -t 0 ] && TASK=$(cat); }
[ -z "$TASK" ] && [ -t 0 ] && [ "$INTERACTIVE" != -1 ] && INTERACTIVE=1
[ -z "$TASK" ] && [ "$INTERACTIVE" != 1 ] && { err "No task. Usage: ./pu.sh \"task\" or ./pu.sh -i"; exit 1; }
case "$PROVIDER" in anthropic) [ -n "${ANTHROPIC_API_KEY:-}" ] || { err "Set ANTHROPIC_API_KEY"; exit 1; };;
  openai) [ -n "${OPENAI_API_KEY:-}" ] || { err "Set OPENAI_API_KEY"; exit 1; };; *) err "Bad provider"; exit 1;; esac
load_context
[ -n "$TASK" ] && TASK=$(expand_refs "$TASK") || true
[ -n "$TASK" ] && { info "$TASK"; info "$MODEL ($PROVIDER) $MAX_STEPS steps"; run_task "$TASK"; exit $?; } || true
info "$MODEL ($PROVIDER) | /model /copy /compact /export /skill:name /quit | !cmd | @file"
while true; do
  _STATE=idle; printf '\033[36m> \033[0m' >&2; read -r INPUT || break
  case "$INPUT" in quit|exit|q) break;; ''|' ') continue;; esac
  handle_cmd "$INPUT" && continue || true
  run_task "$INPUT"
done
