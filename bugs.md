# Bugs and hardening notes for `pu.sh`

This file tracks bugs found during local/LLM review and what happened to them. It is not a guarantee that `pu.sh` is bug-free; it is a compact ledger of known fixed issues and remaining sharp edges.

Current validation:

```sh
sh -n pu.sh
bash eval/test_real.sh
# PASS: 70 FAIL: 0 TOTAL: 70
```

Current size:

```text
400 pu.sh
```

## Recently fixed

### 1. OpenAI Chat Completions shape was wrong for reasoning + tools

**Status:** fixed.

`pu.sh` now uses OpenAI `/v1/responses` instead of Chat Completions for OpenAI mode. Requests use:

```json
{
  "model": "...",
  "max_output_tokens": 4096,
  "reasoning": {"effort":"medium"},
  "instructions": "...",
  "input": [...],
  "tools": [
    {"type":"function","name":"read","parameters":{...},"strict":false}
  ]
}
```

`reasoning` is only sent when the selected model is known to support effort and effort is not `none`.

### 2. OpenAI top-level `output_text` string was not parsed

**Status:** fixed.

Some Responses API shapes expose final text as a top-level string:

```json
{"output_text":"done"}
```

`pu.sh` only parsed nested `{"type":"output_text","text":"..."}` content blocks, so this valid response shape produced an empty final response. It now falls back to `jp "$resp" output_text`.

### 3. OpenAI tool-call continuation dropped required items

**Status:** fixed.

For Responses API tool turns, the script now carries forward:

```json
{"type":"reasoning", ...}
{"type":"function_call", ...}
{"type":"function_call_output", ...}
```

Dropping `reasoning` items can break manually managed Responses conversations, especially with high reasoning effort.

### 4. Context compaction could drop OpenAI reasoning before a function call

**Status:** fixed.

OpenAI can reject a compacted transcript if a retained `function_call` item lost the preceding required `reasoning` item:

```text
Item 'fc_...' of type 'function_call' was provided without its required 'reasoning' item: 'rs_...'
```

`trim_context` now backs up the retained boundary when it would start on `function_call` or `function_call_output`, preserving the required `reasoning → function_call → function_call_output` sequence.

### 5. OpenAI pretty-printed function calls could fail parsing

**Status:** fixed.

Tool-call output is compacted before scanning so multi-line `function_call` items are still found.

### 6. API and transport errors were misreported as empty final responses

**Status:** fixed.

API error JSON such as:

```json
{"error":{"message":"bad key"}}
```

is now reported as an API failure instead of falling through to:

```text
[!] Empty final response
```

Authentication/key errors are treated as non-retryable. Curl/transport failures are retried and reported as transport errors instead of falling through to `Empty final response` or `Max steps`.

### 7. Saved key loading was skipped when `AGENT_MODEL` was set

**Status:** fixed.

`~/.pu.env` is now loaded when no API key is present, even if model/provider env vars are set.

### 8. Pasted API keys could include env-prefix/quotes/whitespace

**Status:** fixed.

Login and env loading sanitize common paste forms:

```text
sk-...
OPENAI_API_KEY=sk-...
OPENAI_API_KEY="sk-..."
  OPENAI_API_KEY="sk-..." 
export OPENAI_API_KEY="sk-..."
  export OPENAI_API_KEY="sk-..."  
```

### 9. Auth header formatting was nonstandard

**Status:** fixed.

Headers now use standard spacing:

```text
Authorization: Bearer ...
x-api-key: ...
```

### 10. High/xhigh effort could consume all visible output budget

**Status:** mitigated.

Output budget now scales by effort:

```text
minimal/low -> at least 4096
medium      -> at least 8192
high        -> at least 16000
xhigh/max   -> at least 32000
```

If OpenAI returns a successful but empty final response, `pu.sh` retries once with a summary prompt and lowers OpenAI effort to `low` for that retry.

### 11. Unsupported effort fields were sent to unsupported models

**Status:** fixed.

`EFFORT_OK` gates reasoning/effort request fields. Non-reasoning OpenAI models such as `gpt-4o` do not receive `reasoning`. `effort=none` suppresses the field.

### 12. `edit` allowed ambiguous replacements

**Status:** fixed.

`edit` now requires exactly one `oldText` match. Empty `oldText` is rejected. Duplicate matches produce an error.

### 13. `edit` used unsafe temporary path and lost executable mode

**Status:** fixed.

`edit` uses `mktemp` in the target directory and preserves the original file mode where possible.

### 14. `write` and `edit` stripped trailing newlines

**Status:** fixed.

Shell command substitution strips trailing newlines. `write`, `oldText`, and `newText` extraction now use sentinel capture so final `\n` survives.

### 15. `read` with `limit:0` behaved inconsistently

**Status:** fixed.

`limit:0` now returns empty output cleanly.

### 16. Non-interactive success could exit with status 1

**Status:** fixed.

The main path now preserves `run_task`'s exit code instead of exiting with the result of the following `[ "$INTERACTIVE" = 1 ]` test.

### 17. Final assistant responses were not saved to history

**Status:** fixed.

Final text is appended as an assistant message before `save`, so `AGENT_HISTORY` and follow-up turns have the prior answer.

### 18. Spinner escapes leaked to redirected stderr

**Status:** fixed.

`spin_stop` only clears/restores the terminal when stderr is a TTY.

### 19. `--pipe "task"` could prepend a blank line when stdin was empty

**Status:** fixed.

Empty stdin plus CLI args no longer creates a leading newline in the task.

### 20. `grep` and `find` walked noisy huge directories

**Status:** mitigated.

`grep` now uses `-I` and skips common directories such as `.git`, `node_modules`, `dist`, `build`, `target`, and `.venv`. `find` prunes the same directories.

### 21. Model errors lacked a useful next step

**Status:** fixed.

Provider errors like `model not found` now also print:

```text
Try /model MODEL
```

### 22. Provider debugging required ad hoc stubs

**Status:** mitigated.

Set `AGENT_DEBUG_API=dir` to capture per-call input and response JSON:

```text
dir/input-STEP-RETRY.json
dir/resp-STEP-RETRY.json
```

### 23. Effort could not be changed interactively

**Status:** fixed.

Use `/effort xhigh`, `/effort low`, or `/effort none`.

### 24. Generic `Inspecting with tools...` spam

**Status:** fixed.

`pu.sh` now prints model commentary only if the provider actually returned text. Otherwise it prints the real tool call line, e.g.:

```text
⏺ read pu.sh
```

## Known remaining limitations / bugs to consider

### 1. Targeted `awk` JSON parsing is fragile

The helpers `jp`, `jb`, `j1st`, and `each_tool_use` are not general JSON parsers. They work for covered provider shapes but can select the wrong key/object if an unexpected response embeds matching keys in strings or changes nesting.

**Possible next step:** optional `jq` fast path with `awk` fallback, or stricter shape-specific scanners.

### 2. `local` is not POSIX

The script uses `local` under `#!/bin/sh`. This works in common shells used as `/bin/sh` on many systems (`dash`, `bash`, BusyBox `ash`, zsh sh emulation), but it is not POSIX.

**Decision:** accepted for now; README says "common sh," not strict POSIX.

### 3. `~/.pu.env` parsing is intentionally tiny

`~/.pu.env` is no longer shell-sourced. A small allowlist parser loads only known keys and ignores arbitrary shell lines.

**Current mitigation:** first-run save uses restrictive permissions via `umask 077`, and malformed/unknown lines are ignored.

**Possible next step:** more robust quote parsing if future values need spaces.

### 4. Context budget is bytes/chars, not tokens

`CTX_LIMIT` and `_ctxp` use `${#MSGS}`. This is approximate and can compact too early or too late.

**Possible next step:** rough token estimator or provider tokenizer integration (but that adds complexity/deps).

### 5. Compaction is heuristic

`trim_context` scans JSON-ish objects and keeps a slice. It has some tool-result boundary handling, but complex OpenAI/Anthropic tool-turn transcripts can still be tricky.

**Possible next step:** compact at explicit logical turn boundaries and validate provider-specific transcript shape after compaction.

### 6. History has no provider/model metadata

`AGENT_HISTORY` stores only the message array. Reusing history across providers can mix incompatible Anthropic/OpenAI transcript items.

**Possible next step:** sidecar metadata or a wrapper object with provider/model.

### 7. `@file` expansion is intentionally simple

Only one simple `@path` reference is expanded. Paths with spaces and multiple refs are not handled well. It also uses direct file read rather than `AGENT_READ_MAX` range behavior.

**Possible next step:** support `@{path with spaces}` and large-file guards.

### 8. `grep` and `find` exclusions are intentionally small

Common noisy directories are pruned, but the list is not exhaustive and may miss repo-specific generated directories.

**Possible next step:** make exclusions configurable without bloating the script.

### 9. Tool errors are plain text, not structured status

Tool failures are returned as text such as:

```text
[exit:2]
```

The model can infer failure, but the provider does not receive a structured tool-error field.

**Possible next step:** provider-specific error/status encoding where supported.

### 10. `edit` metadata preservation is limited

`edit` preserves file mode, but replacement via temp file + `mv` can change ownership, ACLs, xattrs, and symlink behavior.

**Possible next step:** document this more prominently or implement a more metadata-preserving strategy.

### 11. Ctrl-C cleanup only kills direct child

Long-running shell commands with grandchildren can survive because the script tracks only the immediate child pid.

**Possible next step:** process-group cleanup where portable.

### 12. Provider/model defaults may be account-dependent

Defaults are currently:

```text
OpenAI:    gpt-5.5
Anthropic: claude-opus-4-7
```

These may not be available on every account.

**Possible next step:** safer public defaults, model validation, or a clearer first-run warning.

### 13. Anthropic/OpenAI effort support changes over time

Effort/reasoning schemas are model- and date-sensitive. `pu.sh` uses a tiny metadata gate, not a full registry.

**Possible next step:** auto-disable unsupported effort after schema errors.

### 14. No streaming/debug capture mode

When a provider returns a new response shape, debugging requires inspecting logs or adding temporary stubs.

**Possible next step:** `AGENT_DEBUG_API=dir` to save request/response JSON for failed calls.

## Suggested next fix order

1. Optional debug request/response capture.
2. History provider/model metadata.
3. Better compaction boundaries and history provider metadata.
4. `grep`/`find` exclusions for common huge directories.
5. Optional `jq` path or stronger JSON shape parsing.
6. Process-group cleanup on interrupt.
7. Model registry/pricing table if the script can stay small enough.
