# claude-nu

Nushell utilities for working with [Claude Code](https://claude.ai/code) sessions and CLI.

> Work in progress — features are added as needed. If you use Nushell with Claude Code, you might find something useful here.

## Highlights

- **Search past sessions** — Find what you asked Claude last week with `sessions --all-projects | messages 'pattern'`
- **Session analytics** — See what Claude actually did: files touched, tools called, agents spawned, errors hit
- **Smart session picker** — `claude --resume <TAB>` shows age, size, and summary instead of raw UUIDs
- **Export to markdown** — Keep session history in git with YAML frontmatter
- **Move a project** — `project-move <old> <new>` retargets sessions, permissions and prompt history after you move a directory
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

### `claude-nu messages` (search)

Extract user messages from Claude Code session files — and search them: with a regex, every match comes back with its `session` column, a pipeline-safe selector you can drill into.

```nushell no-run
claude-nu messages              # Every message of the current project
claude-nu messages 'pattern'    # ...matching a regex — the project-wide search
claude-nu sessions --all-projects | claude-nu messages 'pattern' # ...across every project
claude-nu sessions --last | claude-nu messages # Just the current session
claude-nu sessions --session <uuid> | claude-nu messages # A named one (tab-completable)
claude-nu messages 'pattern' | claude-nu export-session # Drill matched sessions into markdown
claude-nu messages --include-system # Include system/meta messages
claude-nu messages --raw        # Get raw JSONL records
```

A command handed nothing returns everything at its own level of the current project: `projects` all projects, `sessions` the project's sessions, `messages` its messages. Narrowing is a scope to the left of the pipe, and selection lives in `sessions` alone — so one session, a whole project, or every project is the same command with a different scope in front of it.

Given a regex, `messages` pre-scans the raw JSONL with ripgrep and only parses the sessions that can match; the real regex is then applied to the extracted text. A pattern that leans on a line anchor or a JSON-escaped character can hide from that raw scan — `--no-rg` skips it and matches everything in-engine. Use `find` for filtering a `sessions` table you already have on screen.

Rows come session by session — newest session first, chronological inside each — not as one merged timeline.

**Output:**
| Column | Description |
|--------|-------------|
| `message` | User message content |
| `timestamp` | When message was sent |
| `session` | Session UUID — the selector to pipe onward |
| `project` | Project directory the session belongs to |

`--include-responses` adds `role`; `--raw` replaces `message` with the raw record's `type` and fields.

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
claude-nu sessions --session <uuid> | claude-nu export-session # Specific session
claude-nu export-session --to docs/sessions # Write the markdown to files instead of returning it
claude-nu sessions | claude-nu export-session --to ./tmp # One file per session of the project
```

Without `--to` the command returns `{session, date, topic, markdown}` — pipe it into `get markdown` to read the text before anything touches the disk. With `--to` it writes `<dir>/yyyymmdd-topic.md` and returns `{session, filepath}`; two sessions that would share a filename get the first characters of their session id appended. The directory has no default: naming it is what asks for the write.

Filters out system-generated messages, keeping only user prompts and assistant responses.

### `claude-nu project-move`

Point Claude Code's stored state at a project's new location. Claude keys everything by the absolute project path, so a directory you moved with `mv` leaves its sessions, its permissions and its prompt history stranded under the old name — `claude --resume` in the new place finds nothing. Both arguments are real paths on disk, not encoded directory names.

```nushell no-run
claude-nu project-move ~/old/proj ~/new/proj --dry-run # report what would change, write nothing
claude-nu project-move ~/old/proj ~/new/proj           # do it
```

It rewrites the four places the path is written, and only those: the sessions directory name under `~/.claude/projects`, the `cwd` field in every session record (subagent transcripts included), every mention of the path as a whole quoted string in `~/.claude.json` — its `projects` key and its `githubRepoPaths` entry — and the `project` field in `~/.claude/history.jsonl`. One row per artifact touched comes back, with the number of occurrences replaced; `--dry-run` returns the same rows.

It refuses to merge two projects into one: if Claude already has a sessions directory for the new path, or `~/.claude.json` carries the old path and the new one at once, the move stops. The config check is not cosmetic — the swap is textual, so rewriting the old key when the new one is already there would leave `projects` holding the same key twice, JSON a parser still reads while one project's permissions quietly win. Only the old path and the new one *together* mean a merge: the new path alone is what a run leaves behind when it dies after the config swap, and a rerun has to finish that move rather than call it a collision.

It also refuses to rename a sessions directory that two projects share. The encoded name is lossy — `/work/demo` and `/work-demo` both become `-work-demo` — and the rename takes the whole directory, so the other project's transcripts would land under the new name while everything that points at them still says the old path. When a transcript under the source directory records some other path, the move stops and names the file and the path it found. A transcript recording the new path is a half-finished rerun, and one recording no path at all is a session that died before its first turn — neither is a second project, and neither stops the move.

**What it does not touch.** The project directory itself — move that yourself, this command only fixes what Claude wrote about it. And the old path where it appears inside message texts and tool arguments: those record what happened at the old location, and rewriting them would falsify the transcript. Projects nested under the old path (git worktrees, for instance) are separate projects with their own state; move each one.

**Why a literal substring swap and not a JSON round trip.** A session record is a line of JSON we did not author. Parsing and re-emitting it rewrites every byte of every record — escaping, key order, how numbers are spelled — in order to change one field. Swapping the exact fragment `"cwd":"<old>"` touches only the bytes that encode the path. Measured on one real 62-line session: the path occurs 65 times, 45 of them as that fragment.

**Failure behaviour.** Each file is written through a temp file beside it — seeded by copying the target, so a 0600 `~/.claude.json` does not come back 0644 through the umask — and the rename of the sessions directory comes last. A run that dies partway therefore leaves the sessions under the old name with some `cwd`s already rewritten, and running the same command again finishes exactly what is left: a file already done reports no occurrences and drops out of the next plan. That holds at every point of the run, including after the config swap — the last write before the rename — which is why a `~/.claude.json` carrying only the new path is read as unfinished work and not as a second project to merge. Because `~/.claude.json` is rewritten whole by every running `claude`, its mtime is checked between read and write, turning a lost concurrent save into an error instead of silence. A session file whose bytes are not valid UTF-8 stops the move before anything is written, rather than being skipped in silence.

### `claude-nu gi`

Set up the gi protocol in a repo — where all "what/why" lives in git (the diff and commit body) and the chat carries almost nothing. It comes in two halves. `enable` **seeds** the repo: the Canvas output style and the gi skills. `open` **launches** a session bound to one canvas, creating the canvas if it does not exist yet — that launch is the only thing that turns gi on.

Each verb is a real Nushell subcommand, so it carries its own flags and its own `help claude-nu gi <verb>`, and `claude-nu gi <TAB>` completes them.

```nushell no-run
claude-nu gi enable            # seed style + skills into this repo (no canvas)
claude-nu gi enable --from-session            # ...and start a canvas from this session's dialogue (gi/session-<id>.md)
claude-nu gi enable notes/x.md --from-session # ...at a chosen path
claude-nu gi enable --from-session --tools    # ...keeping tool calls as one-line placeholders
claude-nu gi enable --from-session --commit   # ...and commit it
claude-nu gi enable --from-session --gitignore # ...or keep it out of git
claude-nu gi open              # new canvas + a session bound to it
claude-nu gi open gi/plan.md   # ...a named one: created from the template if new, resumed if it already holds a session
claude-nu gi open gi/plan.md --no-hook # style only, without the Stop-hook floor
claude-nu gi open gi/plan.md --new-session # start over on it: mint a fresh id, overwrite the recorded one
claude-nu gi open gi/plan.md --dangerously-skip-permissions --model opus # ...any other flag goes straight to `claude`
claude-nu gi                   # { canvas, style, skills, stale }
```

**The Stop hook** is the hard floor that comes with every bound session: the agent's final chat message must be `done`/`noted` or a short pointer (one line with a path/link); anything longer blocks the turn with an instruction to move the answer into the canvas and commit it — the block message names the exact file. It also blocks any turn ending on `main`/`master`: gi commits are internal working history; they reach a public branch only squash-merged, after finalization. The "short pointer" length budget defaults to 480 and is tunable via `GI_HOOK_MAX_LEN`.

**Why activation lives at launch.** `gi open` passes the style and the hook to `claude --settings` (which takes inline JSON, merges with the project's settings rather than replacing them) and set `$env.GI_CANVAS` in the launch environment, which the hook inherits as a child process. So gi writes to no settings file at all, and there is nothing to switch off afterwards: a plain `claude` in a seeded repo is a plain session, always. The earlier design put `outputStyle`, the hook, and the canvas path into `.claude/settings.local.json` — repo-wide keys that loaded into *every* session opened there, so a canvas from last week kept shaping unrelated work until you remembered to disable it. `$env.GI_CANVAS` is also the hook's on/off switch: with no canvas bound it has nothing to enforce and stands down.

A repo can hold as many canvases as you like — each `gi open` binds one session to one file, so parallel canvases never collide.

**Your own `claude` flags.** `gi open` is `--wrapped`: anything it does not define is forwarded to `claude` untouched, so `--dangerously-skip-permissions`, `--model`, `--append-system-prompt` and the rest work as usual. Two rules keep the binding honest. Flags gi sets itself — `--settings`, `--session-id`, `--resume`/`-r`, `--continue`/`-c`, `--fork-session`, `--name`, short forms included — are refused, because a second `--settings` wins over gi's and would carry off the style and the Stop hook, leaving gi silently half on. And a flag typed where the canvas goes (`gi open --model opus`) is refused too: nushell hands an undeclared leading flag to the positional, so it would otherwise create a canvas named `--model`. `--dangerously-skip-permissions` is in the signature for that reason — it is the flag most often typed with no canvas named, and being declared it parses in either position.

**One canvas, one session, for life.** On a canvas with no `session:` in its frontmatter, `gi open` mints the session id itself (`claude --session-id`) and writes it in; on one that already has it, the same command resumes that session (`claude --resume`). So the same file reopens into the same conversation days later — a canvas is a working document, not a one-sitting scratchpad — and there is no second verb to pick, because the file already says which case it is. `--new-session` is the way out when that session is gone — deleted, expired, or simply not worth continuing: it mints a fresh id and overwrites the one the canvas records, naming the id it drops as it goes. The launch also passes `--name <canvas>`, which puts the canvas in the prompt box, the `/resume` picker, and the terminal title, so a window says which canvas it belongs to.

**Switching into gi mid-chat:** `--from-session` starts the canvas from the dialogue so far instead of the empty template, so the discussion that led you to gi is the canvas's first content. It reads the session it runs inside (`$env.CLAUDE_CODE_SESSION_ID` — not "the newest session file", which during a live session is as likely a subagent transcript), keeps user messages and Claude's visible replies, and drops tool calls and thinking behind a note pointing at the raw `.jsonl` (`--tools` keeps tool calls as one-line placeholders — useful when the session's value is in what was tried, not only what was said). The turn that runs the import is never in it: Claude Code writes the session log as the turn runs, so the last exchange is still missing. The doc is named for the session (`gi/session-<id>.md`) and is never overwritten — delete it to re-import. It lands in the working tree untracked; `--commit` puts it in git, `--gitignore` keeps it out (they are mutually exclusive). Neither is the default: a transcript carries raw paths and whatever the dialogue quoted, so tracking it is your call — but leaving it ignored means every later gi turn stays out of git too, which is the failure gi exists to prevent.

A canvas seeded this way records the session it was imported from, so `gi open <doc>` reopens **that same session** (`claude --resume`, so the id keeps matching the frontmatter) with the canvas bound, and the agent — still holding the turns the session log could not contain yet — can append that missing tail itself. The `gi-canvas` skill drives the whole flow from inside a chat session, so you don't type nushell into Bash: it runs the import and hands you the one line to run.

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
