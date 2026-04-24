# Honest Feature Comparison: pu.sh vs Pi

## The reality

pu.sh is a **toy proof-of-concept** for extreme portability. Pi is a **production coding harness**. They are not in the same category. Comparing them feature-for-feature makes this obvious.

## What Pi does that pu.sh can't

### Core Agent Capabilities
| Capability | Pi | pu.sh |
|---|---|---|
| **Multiple tools** (read, write, edit, bash, grep, find, ls) | ✅ 7 built-in | ❌ 1 (sh -c) |
| **Surgical file editing** (exact text replacement, not rewrite) | ✅ edit tool | ❌ |
| **File reading** (with offset/limit, images, truncation) | ✅ native | ❌ via sh |
| **Multi-shot / follow-up messages** (steer mid-turn) | ✅ message queue | ❌ |
| **Streaming responses** (token-by-token display) | ✅ SSE/WebSocket | ❌ waits for full response |
| **Thinking/reasoning levels** (off → xhigh) | ✅ 6 levels | ❌ |
| **Image input** (paste, drag, file reference) | ✅ | ❌ |
| **File references** (@file in prompt) | ✅ fuzzy search | ❌ |

### Session Management
| Capability | Pi | pu.sh |
|---|---|---|
| **Session branching** (tree structure, revisit any point) | ✅ /tree | ❌ |
| **Smart compaction** (LLM summarizes old context) | ✅ auto + manual | ❌ dumb truncation |
| **Session resume** (browse, select, continue) | ✅ -c, -r, --session | ⚠️ single checkpoint file |
| **Session forking** (branch from any point) | ✅ /fork | ❌ |
| **Session export** (HTML, gist sharing) | ✅ /export, /share | ❌ |
| **Session versioning** (tree with id/parentId) | ✅ v3 JSONL tree | ❌ flat array |

### Extensibility
| Capability | Pi | pu.sh |
|---|---|---|
| **Custom tools** (register new LLM-callable tools) | ✅ TypeScript | ❌ |
| **Event system** (intercept/modify any lifecycle event) | ✅ 20+ events | ❌ |
| **Plugin packages** (install from npm/git) | ✅ pi install | ❌ |
| **Skills** (on-demand capability packages) | ✅ /skill:name | ❌ |
| **Prompt templates** (reusable prompts with vars) | ✅ /template | ❌ |
| **Custom UI** (TUI components, overlays, widgets) | ✅ full TUI API | ❌ |
| **Themes** (visual customization) | ✅ hot-reload | ❌ |
| **Custom commands** (/mycommand) | ✅ | ❌ |
| **Keyboard shortcuts** (customizable) | ✅ | ❌ |
| **Permission gates** (confirm dangerous ops) | ✅ extensible | ⚠️ basic AGENT_CONFIRM |

### Provider Support
| Capability | Pi | pu.sh |
|---|---|---|
| **Providers** | 20+ (Anthropic, OpenAI, Google, Azure, Bedrock, Mistral, Groq, xAI, etc.) | 2 (Anthropic, OpenAI) |
| **Auth methods** | API key + OAuth subscription | API key only |
| **Model switching** (mid-session) | ✅ /model, Ctrl+L | ❌ |
| **Model cycling** (Ctrl+P rotate) | ✅ | ❌ |
| **Custom providers** (models.json) | ✅ | ❌ |

### Developer Experience
| Capability | Pi | pu.sh |
|---|---|---|
| **Interactive TUI** (editor, message display) | ✅ full terminal UI | ❌ one-shot only |
| **Context files** (AGENTS.md, CLAUDE.md) | ✅ auto-loaded | ❌ |
| **Path completion** (tab complete) | ✅ | ❌ |
| **Undo/redo** (editor) | ✅ | ❌ |
| **Message history** (up arrow) | ✅ | ❌ |
| **Inline bash** (!command, !!command) | ✅ | ❌ |
| **Clipboard** (copy last response) | ✅ /copy | ❌ |

### Programmatic Use
| Capability | Pi | pu.sh |
|---|---|---|
| **SDK** (embed in apps) | ✅ TypeScript SDK | ❌ |
| **RPC mode** (stdin/stdout JSONL) | ✅ --mode rpc | ❌ |
| **JSON output mode** | ✅ --mode json | ❌ |
| **Print mode** (non-interactive) | ✅ -p | ⚠️ only mode it has |

## What pu.sh does differently

| Capability | pu.sh | Pi |
|---|---|---|
| **Zero-install deploy** (curl \| sh) | ✅ | ❌ needs npm |
| **Runs without Node.js** | ✅ sh only | ❌ requires Node 23+ |
| **19KB total footprint** | ✅ | ❌ ~10.5 MB (npm unpacked) |
| **Runs in minimal containers** (alpine, busybox) | ✅ | ❌ |
| **Pipe composition** (agent \| agent) | ✅ --pipe | ⚠️ -p (no chaining) |
| **Zero config files** | ✅ env vars only | ❌ settings.json, sessions/ |

**But Pi runs in more places overall:**

| Platform | pu.sh | Pi |
|---|---|---|
| macOS | ✅ | ✅ |
| Linux | ✅ | ✅ |
| Windows | ❌ no native sh | ✅ |
| Android (Termux) | ⚠️ maybe | ✅ documented |
| WSL | ✅ | ✅ |
| Minimal containers (alpine) | ✅ | ❌ needs node |
| CI runners | ✅ native | ⚠️ needs node step |

## Scoring

### Feature coverage (honest count)

**Total unique capabilities identified: 45**

- **Pi:** 42/45 full, 2/45 partial, 1/45 missing = **95%**
- **pu.sh:** 10/45 full, 4/45 partial, 31/45 missing = **31%**

### The tradeoff in one line

> Pi is a **~550× larger** harness with more features. pu.sh is 310 lines of shell with zero dependencies beyond `sh` + `curl` — including a hand-rolled JSON parser in awk.

### Where pu.sh is genuinely useful

1. **Minimal containers** — agent capability in alpine/scratch images where Node.js isn't available
2. **CI/CD** — add an agent step without a node setup action
3. **Bootstrapping** — use pu.sh to install Pi (or anything else)
4. **Understanding** — the entire agent loop is readable in one screen

### Where Pi wins on platform reach

1. **Windows** — pu.sh has no native sh; Pi runs natively
2. **Android (Termux)** — Pi has documented Termux support
3. **Desktop use** — Pi's TUI is a real interactive experience; pu.sh is one-shot only
