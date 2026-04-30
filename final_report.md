# 🧪 Final Report: The Quest for the Most Portable Agentic Harness

> **"What if an entire coding agent fit in one shell file?"**

## Current state

`pu.sh` is now:

```text
400 lines
32 KB
1 shell file
2 providers: Anthropic + OpenAI
7 tools: bash, read, write, edit, grep, find, ls
90 no-API regression tests passing
```

It started as an experiment in how small a coding-agent harness could be. It ended as a surprisingly capable, still tiny, still very honest shell implementation of the core agent loop.

## The experiment

We set out to answer two questions:

1. What is the **most portable agentic harness** that can be deployed anywhere?
2. How close can a **single shell script** get to a production harness like [Pi](https://pi.dev/)?

What followed was 30+ optimization experiments, multiple bug hunts, an OpenAI Responses migration, and a steady retreat from "pure POSIX minimalism" toward "common sh + curl + awk + common Unix tools, but actually useful."

## Act I: The size wars

**Objective function:** smaller artifact size.

The earliest versions chased raw compression. We proved the core agent loop — prompt, call API, parse tool call, execute tool, append result, repeat — can be tiny. At one point the script was under 7 KB.

That was useful, but too compressed to maintain and too feature-poor to be pleasant.

### Lessons from compression

- Shell compresses extremely well, but readability disappears fast.
- JSON schemas/tool definitions dominate size.
- Function extraction only pays off when reused enough.
- macOS BSD tools are different enough from GNU tools to matter.
- `awk` is the portable escape hatch when `sed` starts lying to you.

## Act II: The parity push

**Objective function:** match the practical shape of Pi.

The script grew back up as we added the pieces that make a coding agent feel real:

```text
✅ 7 named tools
✅ interactive REPL
✅ first-run API-key login
✅ Anthropic Messages API
✅ OpenAI Responses API
✅ OpenAI function tools
✅ reasoning/effort handling
✅ context-file loading
✅ @file references
✅ !command inline shell
✅ skills
✅ prompt templates
✅ default checkpoint/resume via `.pu-history.json`
✅ event logging via `.pu-events.jsonl`
✅ session export
✅ auto/manual compaction with recent-tail budget
✅ status line with cwd/git/tokens/context/provider/model/effort
✅ `/effort` command
✅ debug API capture with `AGENT_DEBUG_API`
✅ grep/find noisy-directory exclusions
✅ confirmation mode
✅ pipe mode
✅ max-step safety fuse, default 100
✅ `/flush` to clear conversation memory
```

The file is larger now, but still small enough to audit in one sitting.

## Act III: The bug hunts

### 1. `set -e` is a silent killer

The most insidious early bug was `set -e`. Shell idioms like:

```sh
[ -f file ] && do_thing
```

return status `1` when the file does not exist. With `set -e`, that can kill the script without a useful error. The fix was to use `set -u`, not `set -e`, and make error handling explicit.

### 2. macOS `sed` is not GNU `sed`

The classic multiline sed pattern from Stack Overflow does not behave the same on macOS. We replaced fragile sed tricks with `awk` for JSON-ish scanning/escaping.

### 3. Heredocs are the wrong abstraction

Models love to emit:

```sh
cat > file <<'EOF'
...
EOF
```

That interacts badly with JSON escaping, shell quoting, and parsing. The system prompt now strongly nudges models to use the `write` tool for file creation.

### 4. OpenAI tool calling moved under our feet

OpenAI reasoning + tools works best through `/v1/responses`, not legacy Chat Completions. The script now sends Responses-shaped tools:

```json
{"type":"function","name":"read","parameters":{...},"strict":false}
```

and continues tool turns with:

```json
{"type":"function_call", ...}
{"type":"function_call_output", ...}
```

It also preserves returned `reasoning` items, because the Responses API expects them when manually managing context.

### 5. High reasoning can consume the whole output budget

`xhigh` reasoning can burn visible-output budget and produce a successful but textless final response. The script now raises `max_output_tokens` by effort and retries empty OpenAI finals at lower effort with a summary prompt.

### 6. API errors must not become "empty final response"

A bad API key used to get retried and then parsed as if it were a normal model response, ending in the misleading:

```text
[!] Empty final response
```

Now API errors are detected directly. Authentication errors are non-retryable.

### 7. Shell command substitution strips trailing newlines

This broke `write` and `edit` for content ending in `\n`. Both now use a sentinel-capture pattern so trailing newlines survive.

### 8. Generic status text can be worse than no text

The script used to print `Inspecting with tools...` whenever a tool-call turn had no model-visible commentary. OpenAI Responses often does that, causing useless spam. Now `pu.sh` only prints real model commentary plus actual tool calls like:

```text
⏺ read pu.sh
⏺ bash sh -n pu.sh
```

## Architecture now

```text
pu.sh
├── setup/auth
│   ├── first-run wizard
│   ├── ~/.pu.env loader
│   └── key sanitization
├── provider layer
│   ├── Anthropic /v1/messages
│   └── OpenAI /v1/responses
├── targeted JSON helpers
│   ├── jp / jb / each_tool_use
│   └── json_escape
├── tool schemas
│   └── bash/read/write/edit/grep/find/ls
├── tool executors
│   ├── exact edit via awk index()
│   ├── read offset/limit
│   └── truncation/confirmation/safety bits
├── agent loop
│   ├── retries
│   ├── API error handling
│   ├── context compaction
│   ├── tool-call continuation
│   └── final response/history save
├── UX
│   ├── REPL
│   ├── status/spinner
│   ├── /commands
│   └── pipe mode
└── session/logging
    ├── `.pu-events.jsonl` event log
    ├── `.pu-history.json` / AGENT_HISTORY checkpoint
    ├── /export
```

## The numbers

```text
Current pu.sh:       396 LOC / 37 KB
Regression suite:    90 behavioral tests
Providers:           2
Tools:               7
Hard runtime deps:   sh + curl + awk + common Unix tools
Compared Pi size:    ~281 MB with Node/package footprint on this machine
```

The old headline was "310 lines / 19 KB." That was true before the OpenAI Responses migration, first-run auth, effort gating, compaction/status UX, and hardening work. The honest current headline is:

> **A 400-line coding agent you can read.**

## What we learned

### 1. The agent loop is simple; the edges are not

The core loop is easy. Everything around it — provider schemas, tool continuity, context overflow, auth, status, history, safety — is where the bugs live.

### 2. A shell script can implement the useful middle

`pu.sh` is not Pi, but it covers the middle of the agent experience:

```text
multi-turn prompt → tools → edits → compaction → final answer
```

That is enough for CI, containers, quick audits, and learning.

### 3. A real runtime wins for UX and correctness

The features shell struggles with are exactly the features a runtime gives you:

```text
streaming
raw terminal mode
keyboard shortcuts
path completion
TUI layout
extension APIs
provider registry
structured JSON parsing
OAuth/browser flows
session tree navigation
```

### 4. OpenAI and Anthropic are not interchangeable

Anthropic tool loops are message/content-block shaped. OpenAI Responses tool loops are item shaped. Trying to pretend they are the same causes bugs.

### 5. Tests are mandatory when your JSON parser is `awk`

The regression suite now checks actual request/response shapes and tool edge cases. That is the only reason this remains sane.

## Current limitations

- Targeted `awk` JSON parsing, not a real JSON parser.
- Only Anthropic and OpenAI.
- No streaming.
- No TUI/editor/history/completion.
- `local` is used under `#!/bin/sh`; works in common shells, not strict POSIX.
- `~/.pu.env` is parsed by a tiny allowlist loader; safer than sourcing, but still minimal.
- Context budget is approximate byte/char count, not tokenization.
- Compaction is heuristic and can still be improved around complex tool boundaries.
- `edit` preserves mode but not owner/ACL/xattrs/symlink semantics.
- `grep`/`find` lack rich exclusions for huge repos.
- No full model registry or built-in pricing table.

## Verdict

**Can you build a real-ish coding agent in a shell script?** Yes.

**Can it replace Pi/Claude Code/Cursor as a daily driver?** No.

**Is it useful anyway?** Absolutely — as a portable agent, CI helper, bootstrapper, and readable reference implementation of the agent loop.

The most portable useful harness is not a giant binary. It is a shell script with just enough scars to know where the real problems are.

---

*30+ experiments. Many bugs. 2 providers. 7 tools. 400 lines. 0 Node.*
