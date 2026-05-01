# pu-unminified.sh Walkthrough

`pu-unminified.sh` is the educational, readable version of `pu.sh`. It is meant to be read as much as it is meant to be run.

This document explains what happens during a run, how provider tool-calling maps to local shell functions, and where to look if you want to modify the script.

## Quick mental model

```text
User task
   ↓
MSGS
   ↓
call_api
   ↓
raw provider JSON
   ↓
parse_response
   ↓
assistant text OR tool call
   ↓
run_tool
   ↓
tool result
   ↓
append
   ↓
repeat
```

The most important idea: the LLM does not directly run commands. It asks for named tools, and the local script decides how to execute those requests.

## Files pu-unminified.sh uses

| File | Purpose |
| --- | --- |
| `.pu-history.json` | Current conversation transcript, reused across turns. |
| `.pu-history.json.meta` | Provider/model metadata for the history file. |
| `.pu-events.jsonl` | Append-only event log for replay, debugging, and export. |
| `~/.pu.env` | Optional saved API key/provider/model configuration. |

## Running a task

Example:

```sh
./pu-unminified.sh "find where the README mentions installation"
```

The script then:

1. Loads configuration from environment variables and `~/.pu.env`.
2. Chooses a provider and model.
3. Loads optional project context files such as `AGENTS.md`, `CLAUDE.md`, `README.md`, `TODO.md`, and docs.
4. Adds your task to `MSGS`.
5. Sends the conversation to the provider with `call_api`.
6. Parses the response with `parse_response`.
7. If the model requested a tool, runs it through `run_tool`.
8. Appends the tool result back into the conversation.
9. Repeats until the model returns final assistant text.

## Provider translation layer

Different APIs represent tool calls differently.

### Anthropic, simplified

```json
{
  "content": [
    {
      "type": "tool_use",
      "id": "toolu_123",
      "name": "read",
      "input": {
        "path": "README.md"
      }
    }
  ]
}
```

### OpenAI Responses, simplified

```json
{
  "output": [
    {
      "type": "function_call",
      "call_id": "call_123",
      "name": "read",
      "arguments": "{\"path\":\"README.md\"}"
    }
  ]
}
```

`parse_response` hides these differences from the main loop by writing normalized parse variables such as:

- `TY`
- `TN`
- `TI`
- `TINP`
- `TX`

## Local tools

The model can ask for these tools:

### `read`

```json
{"path":"README.md","offset":1,"limit":80}
```

Reads a whole file or a line range. `pu-unminified.sh` uses the same default read byte ceiling as `pu.sh`.

### `write`

```json
{"path":"notes.txt","content":"hello\n"}
```

Writes content through a temporary file, then moves it into place.

### `edit`

```json
{
  "path": "main.py",
  "oldText": "print('hello')",
  "newText": "print('hello world')"
}
```

Performs exact text replacement. It fails if `oldText` is missing or appears multiple times. This is deliberate: it prevents vague or accidental edits.

### `grep`

```json
{"pattern":"TODO|FIXME","path":"."}
```

Searches recursively while skipping common dependency/build directories.

### `find`

```json
{"path":".","name":"*.sh"}
```

Discovers files while pruning common dependency/build directories.

### `ls`

```json
{"path":"."}
```

Lists directory contents.

### `bash`

```json
{"command":"printf '%s\n' hello"}
```

Runs a command through the configured shell. The command is written to a temporary file first so multiline commands behave naturally.

## Why explicit tools matter

Tool calls are a safety and observability boundary.

The provider only returns structured JSON. The local script controls:

- which tools exist,
- how paths are interpreted,
- whether writes are atomic,
- whether user confirmation is required,
- how much output is returned,
- how events are logged.

This makes the agent loop inspectable and modifiable.

## Conversation history

The transcript is stored in `MSGS` and persisted to `.pu-history.json`.

The exact JSON shape depends partly on the provider because valid tool-call/result pairs must be preserved. This matters most for OpenAI Responses, where each `function_call_output` must match an earlier `function_call`.

## Context compaction

Long sessions can exceed a model's context window. `trim_context` attempts to keep the session going by:

1. estimating whether the transcript is too large,
2. preserving the first/system-relevant entry,
3. summarizing older middle history,
4. keeping recent tail history,
5. preserving valid provider tool-call/tool-result pairs.

If model-based summarization fails, local compaction builds a simpler memory card from available transcript facts.

## Useful commands

`pu-unminified.sh` intentionally exposes the same command surface as `pu.sh`.

```sh
./pu-unminified.sh --help
./pu-unminified.sh --version
```

Inside interactive mode:

```text
/session
/compact focus text
/export session.md
```

## How to add a new tool

1. Add a JSON schema near the tool schema declarations.
2. Add the tool schema to the provider tool definitions.
3. Add a new case branch in `run_tool`.
4. Validate arguments carefully.
5. Emit a clear textual result.
6. Consider how large output should be handled.
7. Run `sh -n pu-unminified.sh`.
8. Test with a small prompt that asks the model to use the new tool.

## Where to read first

If you are studying the script, read in this order:

1. Header comments and glossary.
2. Tool schema declarations.
3. `call_api`.
4. `parse_response`.
5. `run_tool`.
6. `run_task`.
7. `trim_context`.
8. `handle_cmd`.

That path follows the data flow of a real request while using the same executable names as `pu.sh`.
