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

```nushell no-run
# From the repo directory (or use full paths like ~/git/claude-nu)
use claude-nu
```

## Commands

### `claude-nu -f` (search)

The umbrella entry point. Searches user messages for a regex and returns every match with its `session` column — a pipeline-safe selector you can drill into. Mirrors `help -f`.

```nushell no-run
claude-nu -f 'regex'                # search this project's user messages
claude-nu -f 'regex' --all-projects # search every project under ~/.claude/projects
claude-nu -f 'regex' | claude-nu export-session  # drill matched sessions into markdown
```

It is a shorthand for `sessions | where parent_session_id == null | messages 'regex'`. Use `find` for filtering a `sessions` table you already have on screen, and `-f` for content search from scratch.

### `claude-nu messages`

Extract user messages from Claude Code session files.

```nushell no-run
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

Parse session files into structured data. `--columns` selects what to compute — lazy evaluation, only requested extractions run; the column names tab-complete.

```nushell no-run
claude-nu sessions                                # All sessions in current project (overview columns)
claude-nu sessions ~/other/project                # Sessions from another path
claude-nu sessions --all-projects                 # Every project under ~/.claude/projects
claude-nu sessions --session <uuid>               # Single session (tab-completable)
claude-nu sessions --last --columns token_usage   # Most recent session, just the requested column
claude-nu sessions --columns slug,cwd,git_branch  # Several columns, comma-separated
claude-nu sessions --all-columns                  # All available columns
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

**Additional columns:** request via `--columns name1,name2` (or `--all-columns` for everything). Any `--columns` selection narrows output to `path`/`parent_session_id` plus the requested columns.

| Column | Description |
|--------|-------------|
| `user_messages` | List of user message texts |
| `session_id` | UUID |
| `slug` | Human-readable name |
| `version` | Claude Code version |
| `cwd` | Working directory |
| `git_branch` | Branch at session start |
| `thinking_level` | Thinking mode used |
| `bash_commands` | List of bash commands run |
| `bash_count` | Number of bash commands |
| `skill_invocations` | Skills used |
| `tool_errors` | Failed tool calls |
| `ask_user_count` | User questions asked |
| `plan_mode_used` | Whether plan mode was used |
| `tool_counts` | Per-tool call counts (TaskCreate/Update/Stop, Monitor, ToolSearch) |
| `turn_count` | Authored user turns (excludes meta and tool replies) |
| `assistant_msg_count` | Assistant messages |
| `tool_call_count` | Total tool invocations |
| `token_usage` | Token totals (input/output/cache) |

### `claude-nu export-session`

Export session dialogue to a markdown file for git tracking.

```nushell no-run
claude-nu export-session                    # Uses session summary as topic
claude-nu export-session "auth-refactor"    # Custom topic
claude-nu export-session --session <uuid>   # Specific session
claude-nu export-session | claude-nu save-markdown          # Write to docs/sessions/
claude-nu export-session | claude-nu save-markdown --output-dir ./tmp # Custom output directory
```

**Output format:** `docs/sessions/yyyymmdd-topic.md`

Filters out system-generated messages, keeping only user prompts and assistant responses.

### `claude-nu gi-hook`

Install a per-repo Claude Code **Stop hook** that keeps the chat terse — for the gi protocol, where all "what/why" lives in git (the diff and commit body) and the chat carries almost nothing. When enabled, the agent's final chat message must be `done`/`noted` or a short pointer (one line with a path/link); anything longer blocks the turn with an instruction to move the answer into the working doc and commit it — the block message names the exact file. The hook also blocks any turn ending on `main`/`master`: gi commits are internal working history; they reach a public branch only squash-merged, after finalization. Opt-in and per-repo, so the classic mode is untouched.

```nushell no-run
claude-nu gi-hook enable            # install into this repo's .claude/settings.local.json
claude-nu gi-hook enable notes/x.md # same, choosing the working-doc path (default: gi/canvas-<timestamp>.md)
claude-nu gi-hook disable           # remove it (leaves any other hooks intact)
claude-nu gi-hook status            # { enabled, settings, doc, style, output_style_set }
claude-nu gi-hook check             # hook body — reads the Stop event JSON on stdin
```

The hook lives in `.claude/settings.local.json` (already gitignored by Claude Code), so it never reaches another checkout. `enable` is idempotent and preserves foreign hooks: re-running keeps the recorded working doc, passing a path switches it. `disable` removes only our entries. The "short pointer" length budget defaults to 120 and is tunable via the `GI_HOOK_MAX_LEN` environment variable.

The chosen working-doc path is recorded as `env.GI_HOOK_DOC` in the same settings file; Claude Code exports it into the session, so the agent can locate the canvas via `$env.GI_HOOK_DOC` without being blocked first. `enable` seeds the doc from a template and installs the **Canvas** output style (the proactive half — the hook is the reactive floor) as `.claude/output-styles/canvas.md`, setting `outputStyle` so both turn on together. Seeded files are never overwritten, so your edits are safe; the style loads at session start, so run `/clear` or start a new session after enabling.

## CLI Completions

The repo includes hand-crafted completions for several CLI tools. Add any combination to your `config.nu`:

```nushell no-run
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
# test │ test-unit │ check │ fetch-claude-docs │ …
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

```nushell no-run
nu toolkit.nu test          # Run all tests
nu toolkit.nu test --json   # JSON output for CI
nu toolkit.nu test --fail   # Non-zero exit on failures
```

### Toolkit

```nushell no-run
nu toolkit.nu check <file>             # Static syntax check with diagnostics
nu toolkit.nu fetch-claude-docs        # Download Claude Code docs
nu toolkit.nu fetch-nushell-docs       # Sparse clone of Nushell docs
nu toolkit.nu vendor-sessions          # Obfuscate real sessions into test fixtures
```

## License

MIT
