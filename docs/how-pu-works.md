# How pu works

`pu.sh` is a tiny coding-agent harness built around one loop:

```text
user prompt → provider API → tool call → shell tool → tool result → repeat → final answer
```

It is intentionally small: one shell file, `curl`, `awk`, and common Unix tools. This document explains the moving parts that are too detailed for the main README.

## Files

`pu.sh` uses a few local files with different jobs:

| File | Purpose |
|---|---|
| `.pu-history.json` | Model memory / resumable provider transcript |
| `.pu-events.jsonl` | Event log for replay, debugging, and `/export` |
| `~/.pu.env` | Optional saved API key/provider/model/effort from login |

The split is intentional.

`.pu-history.json` is shaped for the provider. It contains the actual transcript sent back to Anthropic/OpenAI, including OpenAI Responses items like `reasoning`, `function_call`, and `function_call_output`.

`.pu-events.jsonl` is shaped for humans/tools. It logs events like:

```json
{"s":0,"t":"start","c":"find bugs"}
{"s":1,"t":"tool_call","c":"read: {\"path\":\"pu.sh\"}"}
{"s":1,"t":"tool_result","c":"..."}
{"s":2,"t":"response","c":"done"}
```

On startup, if `.pu-history.json` has real memory for the current provider/model, `pu.sh` loads it and replays the last visible messages from the tail of `.pu-events.jsonl`. Use `/flush` to clear memory. Startup intentionally uses a cheap history shape check rather than full JSON validation; full awk validation made resumed sessions noticeably slow.

## Provider loops

### Anthropic

Anthropic uses `/v1/messages`.

The model returns content blocks such as:

```json
{"type":"tool_use","id":"toolu_...","name":"read","input":{"path":"pu.sh"}}
```

`pu.sh` runs the tool and appends a user content block:

```json
{"type":"tool_result","tool_use_id":"toolu_...","content":"..."}
```

### OpenAI

OpenAI uses `/v1/responses`.

Requests use Responses-style tools:

```json
{"type":"function","name":"read","parameters":{...},"strict":false}
```

Tool turns preserve the required item sequence:

```json
{"type":"reasoning", ...}
{"type":"function_call", "call_id":"call_...", "name":"read", "arguments":"{...}"}
{"type":"function_call_output", "call_id":"call_...", "output":"..."}
```

Keeping `reasoning` with its `function_call` matters. OpenAI can reject a transcript if a function call is retained without its required reasoning item.

## Tools

The model can call seven tools:

```text
bash read write edit grep find ls
```

Important semantics:

- `read` supports `offset` and `limit` and refuses very large whole-file reads over `AGENT_READ_MAX`.
- `write` creates parent directories and overwrites the target file via a temp file + `mv` where possible.
- `edit` requires exactly one `oldText` match and rejects empty/non-unique replacements.
- `edit` uses a temp file and preserves executable mode where possible.
- `edit` reads the file as one awk record with `RS="\\001"`. Do not change this to `RS="\\0"`; on macOS/BSD awk, NUL record separators are not a reliable whole-file trick and can make exact matches later in a file fail.
- `grep`/`find` skip common noisy directories like `.git`, `node_modules`, `dist`, `build`, `target`, and `.venv`.
- non-read tool output is truncated if it exceeds `AGENT_TOOL_TRUNC`.

`pu.sh` is not sandboxed. Tools run in your current working directory with your permissions.

## Compaction

Long sessions grow until the provider context would get too large. `pu.sh` auto-compacts before API calls, and you can manually compact with:

```text
/compact [optional focus]
```

Compaction is approximate and byte/char based, not real tokenization. The trigger is:

```text
current_history_bytes > AGENT_CONTEXT_LIMIT - AGENT_RESERVE
```

Defaults:

```text
AGENT_CONTEXT_LIMIT=400000   # 272000 for known Opus-ish defaults
AGENT_RESERVE=16000
AGENT_KEEP_RECENT=80000
```

How compaction works:

1. Split the transcript into top-level JSON-ish entries.
2. Walk backward and keep roughly `AGENT_KEEP_RECENT` bytes/chars of recent work.
3. Back up the cut point if needed so tool boundaries stay valid, especially OpenAI `reasoning → function_call → function_call_output` sequences.
4. Build a bounded, safe summary prompt from the older middle. Extracted transcript entries are first compacted to one JSON object per line by removing whitespace outside strings. The bound then drops whole entries, not arbitrary object fragments. Very large older entries are replaced with ASCII omission markers instead of being byte-sliced, which avoids invalid UTF-8/JSON.
5. Ask the current model to summarize that bounded prompt. If summarization fails, use a local compaction note instead of passing the oversized transcript through unchanged.
6. Rebuild memory as:

```text
[first message, compacted summary, recent tail]
```

If the result is still above the cap, `pu.sh` falls back to:

```text
[first message, compacted summary]
```

That emergency fallback is there so compaction makes progress instead of repeatedly compacting the same oversized transcript.

Important invariant: retained recent entries are reused as raw provider transcript JSON, so they must stay whole and valid. Older entries used only for summarization can be omitted or summarized, but should not be byte-sliced through arbitrary UTF-8. It is not safe to splice truncation markers into retained raw JSON objects. Doing that can produce provider errors such as `Invalid body: failed to parse JSON value`.

This is inspired by Pi's compaction model, but much smaller and less precise. Pi uses token-aware, turn-aware compaction with structured session entries. `pu.sh` uses conservative byte budgets and targeted JSON surgery to stay dependency-free.

## Resume and flush

By default, each directory gets a local memory file:

```text
.pu-history.json
```

To use a different memory file:

```sh
AGENT_HISTORY=my-session.json ./pu.sh
```

To clear memory:

```text
/flush
```

This resets in-memory transcript state and writes:

```json
[]
```

to the history file. It does not delete `.pu-events.jsonl`.

## Retry policy

`pu.sh` retries only failures that are likely transient:

- curl/transport failures retry up to three times.
- context/token-limit errors trigger one forced compaction and retry.
- auth errors, missing-model errors, and invalid request JSON/body errors fail fast.
- successful but empty final responses get one prompt-level retry asking the model to summarize findings.

## Safety fuses

`pu.sh` has a few small safety mechanisms:

| Mechanism | Purpose |
|---|---|
| `AGENT_MAX_STEPS=100` | Stop runaway tool/API loops |
| `AGENT_CONFIRM=1` | Ask before every tool call |
| `AGENT_READ_MAX=1000000` | Refuse huge whole-file reads |
| `AGENT_TOOL_TRUNC=100000` | Truncate large non-read tool output |
| `/flush` | Clear resumed memory |
| `AGENT_DEBUG_API=dir` | Capture request input/response JSON for debugging |

## Limitations

`pu.sh` intentionally does not try to be a production runtime.

Known limitations:

- targeted `awk` JSON parsing, not a general parser
- approximate byte/char context budgets, not real token counting
- no streaming
- no TUI/editor/history navigation
- no sandbox
- only Anthropic and OpenAI
- compaction is heuristic and can still be improved

For a full production harness, use Pi. For a tiny readable harness that works almost anywhere, use `pu.sh`.
