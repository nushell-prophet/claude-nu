# claude-nu

Nushell utilities for working with [Claude Code](https://claude.ai/code) sessions and CLI.

## Features

- **Session analysis** — Extract messages, metadata, and statistics from Claude Code sessions
- **CLI completions** — Full tab completion for the `claude` command with all flags and subcommands
- **Session picker** — Fuzzy-find sessions by UUID with timestamps and summaries

## Installation

### Requirements

- [Nushell](https://www.nushell.sh/)
- [Claude Code](https://claude.ai/code) CLI

### Setup

Add to your `config.nu`:

```nushell
# From the repo directory (or use full paths like ~/git/claude-nu)
use claude-nu
use completions/claude.nu *
```

## Commands

### `claude-nu messages`

Extract user messages from Claude Code session files.

```nushell
claude-nu messages              # Messages from current session
claude-nu messages 'pattern'    # Filter by regex
claude-nu messages --all        # Include system messages
claude-nu messages --raw        # Get raw JSONL records
claude-nu messages -s <uuid>    # Specific session (tab-completable)
```

**Output:**
| Column | Description |
|--------|-------------|
| `message` | User message content |
| `timestamp` | When message was sent |

### `claude-nu sessions`

Parse session files into structured summaries.

```nushell
claude-nu sessions                    # All sessions in current project
claude-nu sessions ~/other/project    # Sessions from another path
```

**Output:**
| Column | Description |
|--------|-------------|
| `summary` | AI-generated session summary |
| `first_timestamp` | Session start time |
| `last_timestamp` | Last activity |
| `user_msg_count` | Number of user messages |
| `agent_count` | Subagents spawned |
| `edited_files` | Files modified |
| `read_files` | Files read |

### `claude-nu parse-session`

Low-level command for extracting specific session data. Uses lazy evaluation—only requested fields are computed.

```nushell
claude-nu parse-session --summary --edited-files
claude-nu parse-session --all     # All available fields
claude-nu parse-session -s <uuid> # Specific session
```

**Available flags:**

| Flag | Description |
|------|-------------|
| `--summary`, `-s` | Session summary |
| `--edited-files` | Files modified by Edit/Write |
| `--read-files` | Files read |
| `--agents`, `-g` | Subagent info |
| `--first-timestamp` | Session start |
| `--last-timestamp` | Last activity |
| `--session-id` | UUID |
| `--slug` | Human-readable name |
| `--version` | Claude Code version |
| `--cwd` | Working directory |
| `--git-branch` | Branch at session start |
| `--thinking-level` | Thinking mode used |
| `--bash-commands` | List of bash commands run |
| `--bash-count` | Number of bash commands |
| `--skill-invocations` | Skills used |
| `--tool-errors` | Failed tool calls |
| `--turn-count` | User→assistant turns |
| `--tool-call-count` | Total tool invocations |
| `--all`, `-a` | Include everything |

### `claude-nu export-session`

Export session dialogue to a markdown file for git tracking.

```nushell
claude-nu export-session                    # Uses session summary as topic
claude-nu export-session "auth-refactor"    # Custom topic
claude-nu export-session -s <uuid>          # Specific session
claude-nu export-session -o ./docs          # Custom output directory
```

**Output format:** `docs/sessions/yyyymmdd+topic.md`

Filters out system-generated messages, keeping only user prompts and assistant responses.

## CLI Completions

The completions file provides tab completion for the entire `claude` CLI:

- All flags with descriptions
- Subcommands (`mcp`, `plugin`, `update`, etc.)
- Values for `--model`, `--output-format`, `--permission-mode`, etc.
- **Session UUIDs** with timestamps and summaries for `--resume`

Example:
```
claude --resume <TAB>
# Shows: abc123... (2 hours ago, 15KB: Implement user auth...)
```

## Development

### Testing

Uses [nutest](https://github.com/vyadh/nutest) framework (expected at `../nutest`).

```nushell
nu toolkit.nu test          # Run all tests
nu toolkit.nu test --json   # JSON output for CI
nu toolkit.nu test --fail   # Non-zero exit on failures
```

### Documentation

Fetch latest Claude Code docs for reference:

```nushell
nu toolkit.nu fetch-claude-docs
```

## How it works

Claude Code stores session data as JSONL files in `~/.claude/projects/<encoded-path>/`. Each file contains:
- Session metadata (summary, timestamps, git branch)
- User messages and assistant responses
- Tool calls and results

This module parses these files to extract useful information for analysis, debugging, and workflow automation.

## License

MIT
