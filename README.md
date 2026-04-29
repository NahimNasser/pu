<p align="center">
  <img src="logo.png" alt="pu.sh" width="500">
</p>

<p align="center"><strong>A full coding-agent harness in 400 lines of shell. Pronounced exactly how you think.</strong></p>

<p align="center"><em>Finally, a slop cannon small enough to fit in your pocket.</em></p>

```sh
curl -sL https://raw.githubusercontent.com/NahimNasser/pu/main/pu.sh -o pu.sh && chmod +x pu.sh
./pu.sh "refactor auth.py to use JWT"
```

That's the entire install. No npm. No pip. No Docker. No runtime. One shell file, common Unix tools, `curl`, `awk`, and an API key.

## What

```sh
# Zero install. Literally.
curl -sL https://raw.githubusercontent.com/NahimNasser/pu/main/pu.sh > pu.sh && chmod +x pu.sh

# First run walks you through provider, key, model, and effort.
./pu.sh

# One-shot task.
./pu.sh "find bugs in pu.sh"

# Interactive multi-turn session.
./pu.sh
> write a REST API server in Go
> now add rate limiting
> write tests for it

# Pipe agents together because we're adults.
./pu.sh "write the code" | ./pu.sh --pipe "review it for security bugs"

# Env-only setup still works.
OPENAI_API_KEY=sk-... AGENT_PROVIDER=openai AGENT_MODEL=gpt-5.5 ./pu.sh "your task"
ANTHROPIC_API_KEY=sk-ant-... AGENT_PROVIDER=anthropic AGENT_MODEL=claude-opus-4-7 ./pu.sh "your task"
```

## Why

We ran [30+ experiments](final_report.md) to answer a question: *what's the most portable agentic harness that can run anywhere?*

The answer is a shell script. The agent loop itself — send prompt, parse response, execute tool, append to history, repeat — is tiny. Everything else is developer experience and hardening.

**Here's the thing nobody tells you:** the `node_modules` folder of a typical coding agent weighs more than the entire Doom source code. Three times over. `pu.sh` weighs less than many README files.

## Features

| What | How |
|---|---|
| **7 tools** | `bash` `read` `write` `edit` `grep` `find` `ls` — Pi-shaped surface area |
| **Interactive REPL** | Multi-turn with memory; `/model` `/effort` `/login` `/logout` `/copy` `/compact` `/export` `/skill:name` `/quit` |
| **First-run login** | API-key wizard for Anthropic/OpenAI, optional private `~/.pu.env` save |
| **Dual provider** | Anthropic Messages API + OpenAI Responses API |
| **OpenAI tool loop** | Preserves `reasoning`, `function_call`, and `function_call_output` items across turns |
| **Reasoning effort** | `AGENT_EFFORT=none|minimal|low|medium|high|xhigh|max`, gated by model support |
| **File editing** | Surgical `oldText` → `newText` replacement; rejects empty or non-unique matches |
| **Safer file writes/edits** | Preserves trailing newlines, uses temp files, keeps executable mode on edits |
| **Context files** | Auto-loads `AGENTS.md` / `CLAUDE.md` from cwd upward, plus global Pi agent context if present |
| **Auto-compaction** | Summarizes older turns when approximate context budget is exceeded; `/compact [focus]` manually compacts |
| **Context/status line** | Shows cwd, git branch, token counts, context usage, provider, model, effort |
| **@file references** | `@src/main.py` inlines file contents into your prompt |
| **!command** | `!ls -la` runs shell inline from the REPL |
| **Prompt templates** | `/name` expands `.pi/prompts/name.md` or `~/.pi/agent/prompts/name.md` |
| **Skills** | `/skill:name` loads `SKILL.md` from local or user skill directories |
| **Session export/fork** | `/export` writes markdown; `/fork` copies the JSONL log |
| **Pipe mode** | `--pipe` for clean stdout, composable with other tools/agents |
| **Checkpoint/resume** | `AGENT_HISTORY=file.json` saves and restores transcript state |
| **Confirmation mode** | `AGENT_CONFIRM=1` asks before every tool execution; safely denies when no TTY |
| **JSONL logging** | Every step logged as structured JSON |
| **Regression tests** | `bash eval/test_real.sh` runs 70 no-API behavioral tests |

## What it can't do

Let's be honest. The remaining gap to a production harness needs a real runtime:

- No TUI (it's a shell script, not a lifestyle)
- No streaming display (curl waits for the full response like a patient person)
- No image input
- No OAuth/browser login; API keys only
- No native Windows support
- No keyboard shortcuts, path completion, themes, or raw-terminal editor
- No package manager or TypeScript plugin SDK
- No full model registry/pricing database
- No general JSON parser; it uses targeted `awk` parsing for provider shapes

`pu.sh` is the same slop cannon but small enough that you can read every line and know exactly where the slop is coming from.

## The Size

```text
pu.sh                32 KB / 400 LOC  █  (sh + curl + awk + common Unix tools)
Claude Code         209 MB            ██████████████████████████
Goose CLI           237 MB            █████████████████████████████
Pi + Node           281 MB            ███████████████████████████████████
SWE-agent Docker    1.8 GB            ██████████████████████████████████████████████████████████████...
```

*Measured locally on macOS arm64. `pu.sh` is `wc -c`/`wc -l` on the file. Larger tools include their runtime/package footprints as described in [final_report.md](final_report.md).*

## Configuration

All env vars. Optional `~/.pu.env` is created by `/login`/first run with `0600`-style permissions and parsed with a tiny allowlist loader.

| Variable | Default | What |
|---|---|---|
| `AGENT_PROVIDER` | auto from key/model, else `anthropic` | `anthropic` or `openai` |
| `AGENT_MODEL` | `claude-opus-4-7` or `gpt-5.5` | Model id |
| `ANTHROPIC_API_KEY` | — | Anthropic API key |
| `OPENAI_API_KEY` | — | OpenAI API key |
| `AGENT_EFFORT` | `medium` | `none|minimal|low|medium|high|xhigh|max`; unsupported models omit effort fields |
| `AGENT_THINKING` | — | Legacy/Anthropic thinking hint; falls back into effort behavior |
| `AGENT_MAX_STEPS` | `25` | Safety limit on agent loops |
| `AGENT_MAX_TOKENS` | `4096` | Base visible-output budget; raised for higher effort |
| `AGENT_CONTEXT_LIMIT` | `400000` OpenAI-ish / `272000` Opus-ish | Approximate context budget in bytes/chars |
| `AGENT_RESERVE` | `16000` | Reserved context budget before compaction |
| `AGENT_TOOL_TRUNC` | `100000` | Max non-read tool output before truncation |
| `AGENT_READ_MAX` | `1000000` | Require offset/limit for larger file reads |
| `AGENT_CONFIRM` | `0` | `1` = ask before each tool call |
| `AGENT_LOG` | `agent.jsonl` | Structured log file |
| `AGENT_HISTORY` | — | Checkpoint file for resume |
| `AGENT_SYSTEM` | built-in | Custom system prompt |
| `AGENT_PRICE_IN_PER_MTOK` / `AGENT_PRICE_OUT_PER_MTOK` | `0` | Optional cost display with `--cost` |
| `AGENT_DEBUG_API` | — | Directory to capture per-call input/response JSON for debugging |

## Commands

| Command | What |
|---|---|
| `/model [id]` | Show or switch model; guesses provider from `gpt-*`/`o*`/`claude-*` |
| `/effort [level]` | Show or set reasoning effort (`none`, `low`, `medium`, `high`, `xhigh`, etc.) |
| `/login` | Run API-key setup wizard |
| `/logout` | Remove `~/.pu.env` and unset in-process keys |
| `/compact [focus]` | Summarize older context, optionally with focus text |
| `/copy` | Copy last response via `pbcopy` or `xclip` |
| `/export [file]` | Export JSONL session log to markdown |
| `/fork` | Copy current JSONL log to a timestamped fork |
| `/skill:name` | Load `name/SKILL.md` into the system prompt |
| `/quit` | Exit |
| `!cmd` | Run a shell command directly |
| `/template` | If `.pi/prompts/template.md` exists, run it as a prompt |

## How it works

```text
┌─────────────────────────────────────────┐
│  You type a thing                       │
│  ↓                                      │
│  curl sends it to Claude/GPT            │
│  ↓                                      │
│  Model asks for a tool                  │
│  ↓                                      │
│  Shell runs read/write/edit/bash/etc.   │
│  ↓                                      │
│  Result goes back to model              │
│  ↓                                      │
│  Model says done                        │
└─────────────────────────────────────────┘
```

400 lines. 7 tools. 2 providers. 1 file. No Node.

OpenAI uses `/v1/responses` with Responses-style tools and `max_output_tokens`. Anthropic uses `/v1/messages`. The parser is targeted `awk`, not a general JSON implementation.

## Testing

```sh
# No API calls, no cost. Current expected result: PASS: 70 FAIL: 0.
bash eval/test_real.sh

# Shell syntax.
sh -n pu.sh
```

The current regression suite covers:

- JSON escaping and targeted JSON extraction
- Anthropic and OpenAI response parsing
- OpenAI Responses request shape and reasoning gating
- OpenAI tool continuation with `reasoning` + `function_call_output`
- API-error reporting, curl transport failures, model-error hints, and non-retryable auth errors
- first-run key sanitization and safe allowlist `~/.pu.env` loading
- history save of final assistant responses
- context compaction invariants
- tool truncation
- edit uniqueness/mode preservation
- `grep`/`find` noisy-directory exclusions and `/effort` command
- trailing-newline preservation for `write`/`edit`
- `read limit:0`
- spinner quietness on non-TTY stderr

## The bugs we found so you don't have to

1. **`set -e` is a serial killer.** `[ -f file ] && do_thing` returns 1 when the file doesn't exist. `set -e` treats that as fatal and silently kills your script. We use `set -u`, not `set -e`.
2. **macOS sed ≠ GNU sed.** The classic multiline sed trick breaks on BSD sed. Use `awk`.
3. **jq was a dependency.** We wrote targeted `awk` JSON extraction to keep install at zero.
4. **Heredocs don't survive JSON reliably.** The system prompt steers models to the `write` tool instead.
5. **OpenAI tool calling is not Chat Completions anymore.** For reasoning + tools, `pu.sh` uses Responses API, carries `reasoning` items forward, and sends `function_call_output` items.
6. **Shell command substitution eats trailing newlines.** `write` and `edit` use sentinel capture to preserve final `\n`.
7. **Generic status spam is worse than silence.** If the model doesn't provide a real pre-tool preamble, `pu.sh` just prints the actual tool call instead of `Inspecting with tools...` forever.

## Prior art & credits

`pu.sh` is a derived work, and we want to be loud about it. The system prompt structure, 7-tool surface (`bash` `read` `write` `edit` `grep` `find` `ls`), exact-text editing model, context-file convention, and skill/template ideas are inspired by **[Pi](https://pi.dev/)**. Huge thanks and respect to the Pi team.

We [compare against Pi](eval/COMPARISON.md) feature-by-feature. Pi wins on extensibility, TUI, providers, safety, and production polish. `pu.sh` wins on portability and inspectability.

## FAQ

**Is this production-ready?**
It's called `pu.sh`. It's a 32KB slop cannon that talks to LLM APIs via `curl`. You tell me.

**Should I use this instead of Pi/Claude Code/Cursor?**
For daily coding, probably not. Use a real tool. For CI/CD, containers, edge boxes, quick scripts, or understanding how agents actually work — `./pu.sh` and see what happens.

**How do I pronounce it?**
However makes your coworkers the most uncomfortable.

**Did you really name a coding agent after feces?**
It's `pu.sh`. As in push. As in `./pu.sh "deploy to prod"`. The fact that it sounds like something else is entirely coincidental and we are very serious engineers.

**Did an AI write this?**
An AI and a human ran experiments, argued with shell, broke OpenAI schemas, fixed them, and learned once again that the real production incident was `set -e` all along.

## License

MIT — see [LICENSE](LICENSE). It's 400 lines. Go nuts.
