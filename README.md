# claude-nu

Nushell utilities for working with [Claude Code](https://claude.ai/code) sessions and CLI.

> Work in progress — features are added as needed. If you use Nushell with Claude Code, you might find something useful here.

## Highlights

- **Search past sessions** — Find what you asked Claude last week with `messages 'pattern' --all-projects`
- **Session analytics** — See what Claude actually did: files touched, tools called, agents spawned, errors hit
- **Smart session picker** — `claude --resume <TAB>` shows age, size, and summary instead of raw UUIDs
- **Export to markdown** — Keep session history in git with YAML frontmatter
- **Dynamic script completions** — `nu` completions that parse any .nu script's subcommands at tab-time
- **Vendored Claude Code skills** — Reusable Nushell style guide and completions guide for Claude Code agents

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
use completions/nu.nu *
use completions/zellij.nu *
use completions/chafa.nu *
use completions/sandbox-exec.nu *
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
| `--ask-user-count` | User questions asked |
| `--plan-mode-used` | Whether plan mode was used |
| `--turn-count` | User→assistant turns |
| `--assistant-msg-count` | Assistant messages |
| `--tool-call-count` | Total tool invocations |
| `--all`, `-a` | Include everything |

### `claude-nu export-session`

Export session dialogue to a markdown file for git tracking.

```nushell
claude-nu export-session                    # Uses session summary as topic
claude-nu export-session "auth-refactor"    # Custom topic
claude-nu export-session -s <uuid>          # Specific session
claude-nu export-session -o ./docs          # Custom output directory
claude-nu export-session --echo             # Print to stdout instead of file
```

**Output format:** `docs/sessions/yyyymmdd+topic.md`

Filters out system-generated messages, keeping only user prompts and assistant responses.

## CLI Completions

Completions are provided for multiple CLI tools:

| File | Command | Highlights |
|------|---------|------------|
| `completions/claude.nu` | `claude` | 50+ flags, MCP/plugin subcommands, session picker for `--resume` |
| `completions/nu.nu` | `nu` | Parses .nu scripts at tab-time to offer their subcommands and flags |
| `completions/zellij.nu` | `zellij` | 100+ actions, live session/layout completers |
| `completions/chafa.nu` | `chafa` | 35+ completers for image rendering options |
| `completions/sandbox-exec.nu` | `sandbox-exec` | macOS sandbox profiles from `/usr/share/sandbox/` |

**Session picker example:**
```
claude --resume <TAB>
# abc123… │ 2 hours ago │ 15KB │ Implement user auth…
# def456… │ yesterday   │ 42KB │ Fix database migration…
```

**Dynamic script completions:**
```
nu toolkit.nu <TAB>
# test │ vendor-skills │ fetch-claude-docs │ …
```

## Development

### Testing

Uses [nutest](https://github.com/vyadh/nutest) framework (expected at `../nutest`).

```nushell
nu toolkit.nu test          # Run all tests
nu toolkit.nu test --json   # JSON output for CI
nu toolkit.nu test --fail   # Non-zero exit on failures
```

### Toolkit

```nushell
nu toolkit.nu fetch-claude-docs        # Download Claude Code docs
nu toolkit.nu fetch-nushell-docs       # Sparse clone of Nushell docs
nu toolkit.nu vendor-skills            # Copy skills from ~/.claude/skills to repo
nu toolkit.nu install-skills-globally  # Copy skills from repo to ~/.claude/skills
```

## How it works

Claude Code stores session data as JSONL files in `~/.claude/projects/<encoded-path>/`. Each file contains:
- Session metadata (summary, timestamps, git branch)
- User messages and assistant responses
- Tool calls and results

This module parses these files to extract useful information for analysis, debugging, and workflow automation.

## License

MIT
