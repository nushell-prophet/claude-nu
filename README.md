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

### `claude-nu gi`

Set up the gi protocol in a repo — where all "what/why" lives in git (the diff and commit body) and the chat carries almost nothing. It comes in two halves. `enable` **seeds** the repo: the Canvas output style and the gi skills. `open`/`resume` **launch** a session bound to one canvas, creating the canvas if it does not exist yet — that launch is the only thing that turns gi on.

```nushell no-run
claude-nu gi enable            # seed style + skills into this repo (no canvas)
claude-nu gi enable --from-session            # ...and start a canvas from this session's dialogue (gi/session-<id>.md)
claude-nu gi enable notes/x.md --from-session # ...at a chosen path
claude-nu gi enable --from-session --tools    # ...keeping tool calls as one-line placeholders
claude-nu gi enable --from-session --commit   # ...and commit it
claude-nu gi enable --from-session --gitignore # ...or keep it out of git
claude-nu gi open              # new canvas + a session bound to it
claude-nu gi open gi/plan.md   # ...a named one, created from the template if new
claude-nu gi open gi/plan.md --no-hook # style only, without the Stop-hook floor
claude-nu gi resume gi/plan.md # continue the session that canvas records
claude-nu gi status            # { canvas, style, skills, stale }
claude-nu gi check             # hook body — reads the Stop event JSON on stdin
```

**The Stop hook** is the hard floor that comes with every bound session: the agent's final chat message must be `done`/`noted` or a short pointer (one line with a path/link); anything longer blocks the turn with an instruction to move the answer into the canvas and commit it — the block message names the exact file. It also blocks any turn ending on `main`/`master`: gi commits are internal working history; they reach a public branch only squash-merged, after finalization. The "short pointer" length budget defaults to 480 and is tunable via `GI_HOOK_MAX_LEN`.

**Why activation lives at launch.** `open`/`resume` pass the style and the hook to `claude --settings` (which takes inline JSON, merges with the project's settings rather than replacing them) and set `$env.GI_CANVAS` in the launch environment, which the hook inherits as a child process. So gi writes to no settings file at all, and there is nothing to switch off afterwards: a plain `claude` in a seeded repo is a plain session, always. The earlier design put `outputStyle`, the hook, and the canvas path into `.claude/settings.local.json` — repo-wide keys that loaded into *every* session opened there, so a canvas from last week kept shaping unrelated work until you remembered to disable it. `$env.GI_CANVAS` is also the hook's on/off switch: with no canvas bound it has nothing to enforce and stands down.

A repo can hold as many canvases as you like — each `open`/`resume` binds one session to one file, so parallel canvases never collide.

**One canvas, one session, for life.** `gi open` mints the session id itself (`claude --session-id`) and writes it into the canvas's frontmatter, so the same file reopens into the same conversation days later with `gi resume <doc>` — a canvas is a working document, not a one-sitting scratchpad. Opening a canvas that already carries a session is refused, with a pointer to `resume`: `claude` rejects an id already on disk ("Session ID … is already in use"), so a second `open` could not work anyway. The launch also passes `--name <canvas>`, which puts the canvas in the prompt box, the `/resume` picker, and the terminal title — so a window says which canvas it belongs to.

**Switching into gi mid-chat:** `--from-session` starts the canvas from the dialogue so far instead of the empty template, so the discussion that led you to gi is the canvas's first content. It reads the session it runs inside (`$env.CLAUDE_CODE_SESSION_ID` — not "the newest session file", which during a live session is as likely a subagent transcript), keeps user messages and Claude's visible replies, and drops tool calls and thinking behind a note pointing at the raw `.jsonl` (`--tools` keeps tool calls as one-line placeholders — useful when the session's value is in what was tried, not only what was said). The turn that runs the import is never in it: Claude Code writes the session log as the turn runs, so the last exchange is still missing. The doc is named for the session (`gi/session-<id>.md`) and is never overwritten — delete it to re-import. It lands in the working tree untracked; `--commit` puts it in git, `--gitignore` keeps it out (they are mutually exclusive). Neither is the default: a transcript carries raw paths and whatever the dialogue quoted, so tracking it is your call — but leaving it ignored means every later gi turn stays out of git too, which is the failure gi exists to prevent.

A canvas seeded this way records the session it was imported from, so `gi resume <doc>` reopens **that same session** (`claude --resume`, so the id keeps matching the frontmatter) with the canvas bound, and the agent — still holding the turns the session log could not contain yet — can append that missing tail itself. The `gi-canvas` skill drives the whole flow from inside a chat session, so you don't type nushell into Bash: it runs the import and hands you the one line to run.

`enable` seeds the **Canvas** output style (the proactive half — the hook is the reactive floor) as `.claude/output-styles/canvas.md`, and the gi skills into `.claude/skills/`. That is all it writes: canvases belong to `gi open`, which creates one from the template and binds a session to it in the same breath, so the two halves never write the same file. A path on `enable` therefore only says where `--from-session` puts its import. Seeded files are never overwritten, so your edits are safe; `--force` refreshes the style and skills from the module, and `status.stale` lists seeds that have drifted from it.

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
# test │ test-unit │ check │ vendor-sessions │ …
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
nu toolkit.nu check [file]             # Static syntax check with diagnostics (whole repo if no file)
nu toolkit.nu vendor-sessions          # Obfuscate real sessions into test fixtures
```

## License

MIT
