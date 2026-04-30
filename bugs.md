# Bugs and hardening notes for `pu.sh`

This file tracks bugs found during local/LLM review and what happened to them. It is not a guarantee that `pu.sh` is bug-free; it is a compact ledger of known fixed issues and remaining sharp edges.

Current validation:

```sh
sh -n pu.sh
bash eval/test_real.sh
# PASS: 90 FAIL: 0 TOTAL: 90
```

Current size:

```text
396 pu.sh
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

### 6b. Empty API responses could exit the caller from inside `run_task`

**Status:** fixed.

After exhausting empty-response retries, `run_task` used `exit 1` instead of `return 1`. In interactive/sourced contexts this could terminate the whole shell instead of reporting failure to the caller. It now returns failure normally; regression coverage is `TC-12b`.

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

`edit` now requires exactly one `oldText` match. Empty `oldText` is rejected. Duplicate/not-found matches produce actionable retry guidance, and failed tool results are shown in the UI. The internal awk readers now use a non-NUL sentinel record separator so exact matches beyond the first line/record are found on BSD/macOS awk.

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

### 25. JSON unicode escapes were only partially decoded

**Status:** fixed.

`jp` previously decoded a few hardcoded escapes (`\u00fc`, curly quotes, dashes) but left most valid JSON unicode escapes literal. Tool arguments such as paths/content containing `\u00e9`, `\u263a`, or surrogate pairs could be passed incorrectly. `jp` now decodes general `\uXXXX` escapes and surrogate pairs while preserving escaped backslash-u sequences like `\\u00e9`; regression coverage is `JS-5b`.

### 26. `write` was non-atomic

**Status:** fixed.

The `write` tool no longer writes directly to the destination with shell redirection. It now writes content to a `mktemp` file in the target directory, applies the existing file mode when overwriting or a normal umask-derived mode for new files, then `mv`s the temp file into place. Symlink paths are resolved before writing so `write` continues to update the linked target rather than replacing the symlink itself.

## Known remaining limitations / bugs to consider

This section is based on direct inspection of the current `pu.sh` script, not README/docs claims. Current syntax checks pass:

```sh
sh -n pu.sh
bash -n pu.sh
```

### 1. `#!/bin/sh` is not strict POSIX

The script advertises "common sh" and uses `#!/bin/sh`, but it uses `local` throughout (`_kill_tree`, `call_api`, `run_tool`, `trim_context`, etc.). `local` works in many common `/bin/sh` implementations (`dash`, BusyBox `ash`, bash-as-sh), but it is not POSIX and can fail on stricter shells.

**Possible next step:** either officially require "common sh with `local`" / switch the shebang to a known shell, or remove `local` usage.

### 2. Targeted `awk` JSON parsing remains fragile

The helpers `jp`, `jb`, `each_tool_use`, and `oa_items` are targeted string scanners, not general JSON parsers. They handle the currently expected provider shapes, including many escapes, but can still select the wrong object/key if provider response formats drift or if matching keys appear in unexpected nested objects/strings.

**Possible next step:** optional `jq` fast path with the current `awk` implementation as fallback, or stricter provider-shape-specific scanners.

### 3. API keys can appear in process arguments

`call_api` passes secrets through curl headers:

```sh
-H "x-api-key: ${ANTHROPIC_API_KEY:-}"
-H "Authorization: Bearer ${OPENAI_API_KEY:-}"
```

On systems where process arguments are visible to other users/processes, API keys can be exposed while a request is running.

**Possible next step:** use a temporary curl config/header file with restrictive permissions, stdin config, or another approach that avoids secrets in argv.

### 4. `edit` metadata preservation is limited

`edit` preserves the original file mode, but replacement through temp file + `mv` can still change ownership, ACLs, extended attributes, hardlink identity, and some symlink semantics.

**Possible next step:** document this clearly or implement a more metadata-preserving strategy for platforms that support it.

### 5. Context compaction can still fail to shrink enough

`trim_context` can return the original oversized context if it cannot find enough JSON-ish objects (`n < 6`). Even after fallback, if the first retained message is huge, the compacted form can still exceed `CTX_LIMIT - AGENT_RESERVE`.

**Possible next step:** add a final hard cap / emergency local summary that guarantees the returned message array is below the byte budget.

### 6. Context budget is bytes/chars, not tokens

`CTX_LIMIT` and `_ctxp` use `${#MSGS}`. This is an approximate byte/character budget, not a model token budget. It can compact too early or too late, especially with non-ASCII text or large JSON/tool payloads.

**Possible next step:** add a conservative token estimator or provider-specific retry/compaction behavior with larger margins.

### 7. Compaction boundaries are heuristic

`trim_context` scans JSON-ish objects and tries to avoid starting on OpenAI reasoning/function-call/tool-output boundaries. This is still heuristic. Complex Anthropic/OpenAI tool-turn transcripts can still be malformed after compaction.

**Possible next step:** compact at explicit provider-specific logical turn boundaries and validate the resulting transcript shape before sending it.

### 8. Ctrl-C cleanup depends on `pgrep`

`_interrupt` calls `_kill_tree`, which recursively kills descendants when `pgrep -P` is available. Without `pgrep`, or for fully detached/reparented processes, runaway descendants may survive.

**Possible next step:** run tools/API calls in their own process group where available and kill the group on interrupt.

### 9. Provider/model defaults may be account-dependent

Defaults are currently:

```text
OpenAI:    gpt-5.5
Anthropic: claude-opus-4-7
```

These may not be available on every account, so first run can fail with a model access/not-found error.

**Possible next step:** choose safer public defaults, add model validation, or improve first-run model selection.

### 10. Reasoning/effort schemas can drift

`think_param`, `EFFORT_OK`, and OpenAI/Anthropic request fields are hardcoded. Effort/reasoning APIs are model- and date-sensitive; a provider schema change can produce invalid-body errors.

**Possible next step:** auto-disable effort after schema errors, or maintain a small model capability registry.

### 11. `bash` tool is unsandboxed

The `bash` tool writes model-provided commands to a temp file and executes them with `$RUNSH`. This is expected for a coding agent, but it is unsafe for untrusted prompts/context or hostile repositories.

**Possible next step:** keep `AGENT_CONFIRM=1` documented, add optional deny/allow lists, or support a sandbox/worktree mode.

### 12. Debug capture can leak sensitive data

`AGENT_DEBUG_API=dir` writes full request/response JSON to disk, including prompts, file contents, tool outputs, and possibly secrets copied into context.

**Possible next step:** add redaction, rotation, and a warning when debug capture is enabled.

### 13. Dependency story is broader than `sh + curl + awk`

The script checks only `curl` and `awk`, but uses other common Unix tools: `sed`, `tr`, `dirname`, `mktemp`, `grep`, `find`, `head`, `tail`, `wc`, `cat`, `stat`, `chmod`, `mv`, `readlink`, and optionally `pgrep`, `git`, `open`/`xdg-open`.

**Possible next step:** update the stated requirement to "common Unix userland" or add startup checks for less-universal tools.

### 14. Tool errors are plain text, not structured status

Tool failures are returned as text such as:

```text
[exit:2]
Error: oldText not found ...
```

The model can infer failure, but the provider does not receive a structured tool-error field.

**Possible next step:** provider-specific error/status encoding where supported.

### 15. History compatibility is guarded by a sidecar

`.pu-history.json` / `AGENT_HISTORY` stores the message array, and `save` writes a `.meta` sidecar containing provider/model. This prevents normal cross-provider resume, but the history file itself is still not self-describing if copied without its sidecar.

**Possible next step:** store history as a wrapper object with provider/model/messages instead of relying on a separate `.meta` file.

### 16. No `@file` expansion

Tasks that mention files are sent as plain text; the model must use the `read` tool. This avoids hidden large-file reads but is less convenient than explicit `@path` inclusion.

**Possible next step:** optional guarded `@{path}` expansion with `AGENT_READ_MAX`/range behavior.

## Suggested next fix order

1. Guarantee compaction returns a context under budget.
2. Reduce API key exposure in curl process arguments.
3. Add an optional `jq` path or strengthen JSON parsing.
4. Clarify shell/dependency requirements or remove non-POSIX assumptions.
5. Add process-group cleanup where available.
6. Add safer model defaults/model validation.
7. Add debug redaction/rotation if `AGENT_DEBUG_API` remains.
