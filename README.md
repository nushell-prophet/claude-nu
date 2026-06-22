# claude-nu

Nushell utilities for working with [Claude Code](https://claude.ai/code) sessions and CLI.

> Work in progress — features are added as needed. If you use Nushell with Claude Code, you might find something useful here.

## Highlights

- **Search past sessions** — Find what you asked Claude last week with `sessions --all-projects | messages 'pattern'`
- **Session analytics** — See what Claude actually did: files touched, tools called, agents spawned, errors hit
- **Smart session picker** — `claude --resume <TAB>` shows age, size, and summary instead of raw UUIDs
- **Export to markdown** — Keep session history in git with YAML frontmatter
- **Dynamic script completions** — `nu` completions that parse any .nu script's subcommands at tab-time
- **Claude Code skills** — Opinionated Nushell style guide and completions guide, distributed via [plugin marketplace](https://github.com/nushell-prophet/nushell-skills)

## Installation

### Requirements

- [Nushell](https://www.nushell.sh/)
- [Claude Code](https://claude.ai/code) CLI

### Setup

Add to your `config.nu`:

```nushell
# From the repo directory (or use full paths like ~/git/claude-nu)
use claude-nu
```

## Commands

### `claude-nu messages`

Extract user messages from Claude Code session files.

```nushell
claude-nu messages              # Messages from current session
claude-nu messages 'pattern'    # Filter by regex
claude-nu messages --include-system # Include system/meta messages
claude-nu messages --raw        # Get raw JSONL records
claude-nu messages --session <uuid> # Specific session (tab-completable)
```

**Output:**
| Column | Description |
|--------|-------------|
| `message` | User message content |
| `timestamp` | When message was sent |

### `claude-nu sessions`

Parse session files into structured data. Column flags select what to compute — lazy evaluation, only requested extractions run.

```nushell
claude-nu sessions                        # All sessions in current project (overview columns)
claude-nu sessions ~/other/project        # Sessions from another path
claude-nu sessions --all-projects         # Every project under ~/.claude/projects
claude-nu sessions --session <uuid>       # Single session (tab-completable)
claude-nu sessions --last --token-usage   # Most recent session, just the requested column
claude-nu sessions --all-columns          # All available columns
```

**Default (overview) columns:**
| Column | Description |
|--------|-------------|
| `summary` | AI-generated session summary |
| `first_timestamp` | Session start time |
| `last_timestamp` | Last activity |
| `user_msg_count` | Number of user messages |
| `user_msg_length` | Total chars typed by user |
| `response_length` | Total chars of assistant text |
| `agent_count` | Subagents spawned |
| `agents` | Subagent info |
| `mentioned_files` | @-mentions in user messages |
| `read_files` | Files read |
| `edited_files` | Files modified by Edit/Write |
| `path` | Session file path |
| `parent_session_id` | Parent UUID for subagent transcripts |

**Column flags:** any column flag switches output to `path`/`parent_session_id` plus the requested columns. Overview columns have flags too (`--summary`, `--first-timestamp`, …); the rest:

| Flag | Description |
|------|-------------|
| `--user-messages` | List of user message texts |
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
| `--tool-counts` | Per-tool call counts (TaskCreate/Update/Stop, Monitor, ToolSearch) |
| `--turn-count` | User→assistant turns |
| `--assistant-msg-count` | Assistant messages |
| `--tool-call-count` | Total tool invocations |
| `--token-usage` | Token totals (input/output/cache) |
| `--all-columns` | Include everything |

### `claude-nu export-session`

Export session dialogue to a markdown file for git tracking.

```nushell
claude-nu export-session                    # Uses session summary as topic
claude-nu export-session "auth-refactor"    # Custom topic
claude-nu export-session --session <uuid>   # Specific session
claude-nu export-session | claude-nu save-markdown          # Write to docs/sessions/
claude-nu export-session | claude-nu save-markdown --output-dir ./tmp # Custom output directory
```

**Output format:** `docs/sessions/yyyymmdd-topic.md`

Filters out system-generated messages, keeping only user prompts and assistant responses.

## CLI Completions

The repo includes hand-crafted completions for several CLI tools. Add any combination to your `config.nu`:

```nushell
use completions/claude.nu *
use completions/nu.nu *
use completions/zellij.nu *
use completions/chafa.nu *
use completions/sandbox-exec.nu *
```

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

### Claude Code Skills

Nushell-specific skills for Claude Code are distributed as a plugin marketplace:

```
/plugin marketplace add nushell-prophet/nushell-skills
/plugin install nushell-completions@nushell-skills
/plugin install nushell-style@nushell-skills
```

| Plugin | What it does |
|--------|-------------|
| `nushell-completions` | Teaches Claude Code to write Nushell completions — inline lists, custom completers, `extern` definitions, module naming rules. Point it at `--help` output and it produces a ready-to-use completion file. |
| `nushell-style` | Opinionated Nushell style guide — pipeline patterns, command choices, formatting conventions, testing patterns. Activates automatically when editing `.nu` files. |

All completions in this repo were built with the `nushell-completions` skill.

## How it works

Claude Code stores session data as JSONL files in `~/.claude/projects/<encoded-path>/`. Each file contains:
- Session metadata (summary, timestamps, git branch)
- User messages and assistant responses
- Tool calls and results

This module parses these files to extract useful information for analysis, debugging, and workflow automation.

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

## License

MIT
