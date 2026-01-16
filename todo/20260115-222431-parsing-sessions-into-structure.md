---
status: planned
created: 20260115-222431
updated: 20260115-224500
---

# Initial request (only the user can edit this section)

I need a command to parse Claude Code sessions for structured information:

1. Count of user messages
2. `str length` of user messages
3. Timestamps (first and last)
4. `str length` of Claude Code responses
5. Count of agent usages
6. List of mentioned files
7. List of read files
8. List of edited files

The command needs a flag to specify the list of paths, a single path, or a directory to parse.

# LLM agent updates section

## Research Findings (2026-01-15)

### Existing codebase:
- `messages` command: extracts user messages from sessions
- `get-sessions-dir`: returns `~/.claude/projects/<encoded-path>/` for current project
- Session files: JSONL with record types `summary`, `user`, `assistant`

### Session file structure:
```
{type: "summary", summary: "..."}
{type: "user", timestamp: "...", message: {content: "..."}}
{type: "assistant", message: {content: [{type: "text", text: "..."}, {type: "tool_use", name: "Read", input: {file_path: "..."}}]}}
```

### Agent usage:
- Tool name: `Task`
- Agent type: `input.subagent_type` (e.g., "Explore", "commit-git", "general-purpose")
- Description: `input.description`

### Visible response text:
- Filter `message.content[]` where `type == "text"`, extract `.text`
- Excludes: `thinking`, `tool_use`, `tool_result` blocks

---

## Implementation Plan

### Command signature:
```nushell
claude-nu sessions ...paths: path
```
- Positional rest args only (files or directories)
- If directory: parse all `*.jsonl` session files within
- **Default**: if no paths provided, use `get-sessions-dir` (current project's sessions)

### Output table (one record per session):

| Field | Type | Source |
|-------|------|--------|
| `path` | path | session file path |
| `summary` | string | `type: "summary"` record |
| `first_timestamp` | datetime | earliest user message timestamp |
| `last_timestamp` | datetime | latest user message timestamp |
| `user_msg_count` | int | count of `type: "user"` records |
| `user_msg_length` | int | total str length of user message content |
| `response_length` | int | total str length of visible assistant text |
| `agent_count` | int | count of `Task` tool calls |
| `agents` | list | `[{type: string, description: string}]` |
| `mentioned_files` | list | `@path` patterns extracted from user messages |
| `read_files` | list | unique `file_path` from `Read` tool inputs |
| `edited_files` | list | unique `file_path` from `Edit`/`Write` tool inputs |

---

## Status: Ready to implement

