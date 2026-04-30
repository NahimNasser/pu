# Honest Feature Comparison: pu.sh vs Pi

## The reality

`pu.sh` is a tiny, inspectable coding-agent harness optimized for extreme portability. Pi is a production-grade coding agent with a real runtime, TUI, extension system, model registry, and provider ecosystem.

They are not in the same category. That is the point.

## Current snapshot

| Dimension | Pi | pu.sh |
|---|---|---|
| Runtime | Node/TypeScript app | One `#!/bin/sh` file |
| Size on this machine | ~281 MB with Node/package footprint | 37 KB / 396 LOC |
| Providers | 20+ | 2: Anthropic + OpenAI |
| Auth | API keys + richer provider flows | API keys + optional `~/.pu.env` |
| UI | Full TUI | plain REPL / pipe mode |
| Tools | Extensible typed tools | 7 built-ins |
| Streaming | yes | no |
| Extensions | TypeScript packages/events/TUI APIs | no runtime plugin SDK |
| Best use | daily driver / production harness | minimal machines, CI, demos, understanding agents |

## Core agent capabilities

| Capability | Pi | pu.sh |
|---|---|---|
| `bash` tool | ✅ | ✅ |
| `read` tool | ✅ offset/limit + richer media support | ✅ text, offset/limit, large-file guard |
| `write` tool | ✅ | ✅ preserves trailing newlines |
| `edit` tool | ✅ robust exact replacement | ✅ exact replacement, rejects non-unique matches, preserves mode |
| `grep` tool | ✅ | ✅ recursive grep with common noisy-dir exclusions |
| `find` tool | ✅ | ✅ find/glob with common noisy-dir pruning |
| `ls` tool | ✅ | ✅ |
| Tool-call loop | ✅ | ✅ Anthropic + OpenAI Responses |
| OpenAI Responses tools | ✅ provider implementation | ✅ function tools + `function_call_output` |
| OpenAI reasoning continuation | ✅ | ✅ carries `reasoning` items forward |
| Multi-turn chat | ✅ | ✅ REPL/history in memory |
| Pipe/print mode | ✅ | ✅ `--pipe` / `-n` |
| Streaming tokens/events | ✅ | ❌ waits for curl response |
| Image input | ✅ | ❌ |
| Follow-up/steering mid-turn | ✅ | ❌ no async stdin |

## Session and context

| Capability | Pi | pu.sh |
|---|---|---|
| Context files (`AGENTS.md`, etc.) | ✅ | ✅ `AGENTS.md` / `CLAUDE.md`, plus global Pi agent context if present |
| Context status | ✅ token-aware | ⚠️ byte/char approximation shown in status |
| Auto-compaction | ✅ robust turn-aware compaction | ⚠️ LLM summary with heuristic transcript slicing |
| Manual compaction | ✅ | ✅ `/compact [focus]` |
| Session resume | ✅ session browser / IDs | ⚠️ `AGENT_HISTORY=file.json` only |
| Session tree | ✅ | ❌ |
| Session fork | ✅ | ⚠️ copies `.pu-events.jsonl` with `/fork` |
| Export/share | ✅ rich export/share | ⚠️ markdown export from event log |
| Provider-compatible history metadata | ✅ | ❌ user must avoid mixing incompatible histories |

## Commands and workflow

| Capability | Pi | pu.sh |
|---|---|---|
| `/model` | ✅ rich model selector | ⚠️ simple model switch/guess provider |
| `/effort` | ✅ | ✅ simple effort switch |
| `/login` / `/logout` | ✅ provider auth flows | ✅ API-key wizard, no OAuth |
| `/copy` | ✅ | ✅ via `pbcopy`/`xclip` |
| `/skill:name` | ✅ | ✅ loads `SKILL.md` text into prompt |
| Prompt templates | ✅ | ✅ `/name` from `.pi/prompts` or user prompt dir |
| `@file` references | ✅ fuzzy/path UX | ⚠️ simple single `@path` expansion |
| Inline shell `!cmd` | ✅ | ✅ |
| Keyboard shortcuts | ✅ | ❌ |
| Path completion | ✅ | ❌ |
| TUI editor/history | ✅ | ❌ plain `read -r` |
| Themes | ✅ | ❌ terminal theme only |

## Provider/model support

| Capability | Pi | pu.sh |
|---|---|---|
| Anthropic | ✅ | ✅ Messages API |
| OpenAI | ✅ | ✅ Responses API |
| Google/Gemini | ✅ | ❌ |
| Azure/OpenAI-compatible variants | ✅ | ❌ |
| Bedrock/Vertex/etc. | ✅ | ❌ |
| Custom provider definitions | ✅ | ❌ |
| Model registry/context/prices | ✅ | ⚠️ tiny hard-coded metadata + optional price env vars |
| Reasoning effort | ✅ model-aware | ⚠️ gated for known model prefixes; unsupported models omit effort fields |
| OAuth/subscription auth | ✅ where supported | ❌ API keys only |

## Extensibility and safety

| Capability | Pi | pu.sh |
|---|---|---|
| Custom tools | ✅ TypeScript API | ❌ edit the script |
| Event system/hooks | ✅ | ❌ |
| Extension packages | ✅ | ❌ |
| Custom TUI components | ✅ | ❌ |
| Permission system | ✅ richer | ⚠️ `AGENT_CONFIRM=1` prompt before tools |
| Tool schemas | ✅ typed | ⚠️ hand-written JSON schemas |
| Structured tool errors | ✅ stronger provider abstractions | ⚠️ error text returned to model |
| File metadata preservation | ✅ better abstractions | ⚠️ edit preserves mode, not owner/ACL/xattrs/symlink semantics |
| JSON parsing | ✅ real parser/runtime | ⚠️ targeted `awk` parser; fragile by design |

## Platform reach

| Platform | Pi | pu.sh |
|---|---|---|
| macOS | ✅ | ✅ |
| Linux | ✅ | ✅ |
| Windows native | ✅ | ❌ needs sh/WSL/MSYS/etc. |
| WSL | ✅ | ✅ |
| Android/Termux | ✅ documented | ⚠️ likely if common tools/curl/awk exist |
| Minimal containers | ⚠️ needs Node | ✅ strong fit |
| CI runners | ✅ setup Node | ✅ copy one file |

## Feature coverage estimate

The old comparison claimed `pu.sh` only had one tool and no interactive mode. That is outdated.

A current rough count across the same broad areas:

- **Pi:** ~95%+ of production-agent features in this comparison.
- **pu.sh:** ~55–65% of the practical agent loop/workflow features, but far less of the TUI/provider/extensibility surface.

`pu.sh` now covers the core loop surprisingly well:

```text
prompt → provider API → tool call → shell tool → tool result → repeat → final answer
```

But Pi remains far ahead on everything that benefits from a real runtime: streaming, TUI, extensions, provider breadth, model registry, session trees, safety policies, and structured parsing.

## The tradeoff in one line

> Pi is the real coding agent. `pu.sh` is the smallest useful fossil of one: ~400 lines, 37 KB, `sh` + `curl` + `awk`, and no build step.

## Where pu.sh is genuinely useful

1. **Minimal containers** — agent capability where Node.js is not installed.
2. **CI/CD** — add an agent step without a setup action.
3. **Bootstrapping** — use `pu.sh` to install/debug other tools.
4. **Auditing/learning** — read the whole agent loop in one file.
5. **Emergency shells** — copy one file, set an API key, get tools.

## Where Pi wins hard

1. **Daily development** — TUI, streaming, history, shortcuts, completion.
2. **Provider/model breadth** — real registry and many backends.
3. **Extensibility** — TypeScript plugins, events, tools, UI.
4. **Safety and correctness** — structured runtime beats shell parsing.
5. **Long sessions** — session trees, compaction, recovery, metadata.

Different tools. Different problems. Same basic agent shape.
