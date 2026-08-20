# claude-nu

Nushell utilities for working with [Claude Code](https://claude.ai/code) sessions and CLI.

> Work in progress — features are added as needed.
> If you use Nushell with Claude Code, you might find something useful here.

## Highlights

- **Search past sessions** — Find what you asked Claude last week with `sessions --all-projects | messages 'pattern'`
- **Session analytics** — See what Claude actually did: files touched, tools called, agents spawned, errors hit
- **Search what the agent ran** — `tool-calls 'pattern'` searches the tool calls themselves, not only what was typed
- **Smart session picker** — `claude --resume <TAB>` shows age, size, and summary instead of raw UUIDs
- **Export to markdown** — Keep session history in git with YAML frontmatter
- **Move a project** — `project-move <old> <new>` retargets sessions, permissions and prompt history after you move a directory
- **Try a pipeline** — `claude-nu example <TAB>` picks one of the module's own `@example` pipelines and pastes it into your command line
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
claude-nu messages --since 1wk  # ...sent in the last week (see The time window)
claude-nu messages --include-system # Include system/meta messages
claude-nu messages --raw        # Get raw JSONL records
```

A command handed nothing returns everything at its own level of the current project: `projects` all projects, `sessions` the project's sessions, `messages` its messages.
Narrowing is a scope to the left of the pipe, and selection lives in `sessions` alone — so one session, a whole project, or every project is the same command with a different scope in front of it.

Given a regex, `messages` pre-scans the raw JSONL with ripgrep and only parses the sessions that can match; the real regex is then applied to the extracted text.
A pattern that leans on a line anchor or a JSON-escaped character can hide from that raw scan — `--no-rg` skips it and matches everything in-engine.
Use `find` for filtering a `sessions` table you already have on screen.

Rows come session by session — newest session first, chronological inside each — not as one merged timeline.

**Output:**
- `message` — User message content
- `timestamp` — When message was sent
- `session` — Session UUID, the selector to pipe onward
- `project` — Project directory the session belongs to

`--include-responses` adds `role`; `--raw` replaces `message` with the raw record's `type` and fields.

### `claude-nu tool-calls`

What an agent *did*, as `messages` is what was said: one row per tool call.
Scoping and searching work exactly as in `messages` — no input reads every top-level session of the current project, piped session rows narrow it, the regex argument gets the same ripgrep pre-filter over the raw JSONL, and `--no-rg` turns that off.

```nushell no-run
claude-nu tool-calls                       # Every tool call of the current project
claude-nu tool-calls 'claude-nu sessions'  # ...whose input matches a regex
claude-nu sessions --all-projects | claude-nu tool-calls 'npm test' # ...across every project
claude-nu tool-calls --since 1day | where tool == Bash | get input.command # filtering by tool is a plain `where`
```

**Output:**
- `tool` — Tool name (`Bash`, `Edit`, `Agent`, an MCP tool's full name, ...)
- `input` — The call's arguments, as the raw record, so you drill in: `get input.command`
- `timestamp` — When the call was made
- `session` — Session UUID, the selector to pipe onward
- `project` — Project directory the session belongs to

The regex is applied to the whole input rendered as NUON, not to one field.
Which field holds the interesting string depends on the tool — `command` for Bash, `prompt` for Agent, its own schema for an MCP tool — so a search that had to name the field could only answer "who ran this" for Bash.

**Why this is not a `sessions` column.**
`bash_commands` was the only other window onto agent actions and it reads the Bash tool alone.
Mining this machine's whole session store for `claude-nu` invocations, 82 of the 588 an agent made came through the nushell MCP server and were invisible there.
It also aggregates per session, so a matched command has no timestamp and no row of its own, and the `--columns` path has no ripgrep pre-filter: the same all-projects sweep took 42s through `sessions --columns bash_commands` against 2.4s once ripgrep narrowed the files first.

### `claude-nu sessions`

Parse session files into structured data.
`--columns` selects what to compute — lazy evaluation, only requested extractions run; the column names tab-complete.

```nushell no-run
claude-nu sessions                                # All sessions in current project (overview columns)
claude-nu sessions ~/other/project                # Sessions from another path
claude-nu sessions --all-projects                 # Every project under ~/.claude/projects
claude-nu sessions --session <uuid>               # Single session (tab-completable)
claude-nu sessions --last --columns token_usage   # Most recent session, just the requested column
claude-nu sessions --columns version,cwd,git_branch  # Several columns, comma-separated
claude-nu sessions --all-columns                  # All available columns
claude-nu sessions --since 1wk                    # Active in the last week — see The time window
```

**Default (overview) columns:**
- `summary` — AI-generated session summary
- `first_timestamp` — Session start time
- `last_timestamp` — Last activity
- `user_msg_count` — Number of user messages
- `user_msg_length` — Total chars typed by user
- `response_length` — Total chars of assistant text
- `agent_count` — Subagents spawned
- `agents` — Subagent info
- `mentioned_files` — @-mentions in user messages
- `read_files` — Files read
- `edited_files` — Files modified by Edit/Write
- `path` — Session file path
- `parent_session_id` — Parent UUID for subagent transcripts

**Additional columns:** request via `--columns name1,name2` (or `--all-columns` for everything).
Any `--columns` selection narrows output to `path`/`parent_session_id` plus the requested columns.

- `user_messages` — List of user message texts
- `session_id` — UUID
- `version` — Claude Code version
- `cwd` — Working directory
- `git_branch` — Branch at session start
- `effort` — Reasoning effort the session ran at
- `bash_commands` — List of bash commands run
- `bash_count` — Number of bash commands
- `skill_invocations` — Skills used
- `tool_errors` — Failed tool calls
- `ask_user_count` — User questions asked
- `plan_mode_used` — Whether plan mode was used
- `tool_counts` — Per-tool call counts (TaskCreate/Update/Stop, Monitor, ToolSearch)
- `turn_count` — Authored user turns (excludes meta and tool replies)
- `assistant_msg_count` — Assistant messages
- `tool_call_count` — Total tool invocations
- `token_usage` — Token totals (input/output/cache)

### The time window

`--since` and `--until` are on `sessions`, `messages` and `tool-calls`.
Each takes a duration meaning *ago* (`--since 1wk`, `--until 3day`), a date (`2026-08-01`), or a `datetime` value — so "what did I do last week" is a flag, not a filter you write afterwards.

What the window is measured against is the row you are asking for.
In `messages` and `tool-calls` a row is one message or one call, so the window is compared to its own timestamp.
In `sessions` a row is a whole session, timed by its file's mtime — its last activity, the same clock that already orders every listing here.
Deciding the window from a parsed `first_timestamp` instead would have to parse every session to find out which sessions to parse, which is the cost the window exists to avoid.

`--since` also makes the work smaller before any file is opened: a session file untouched since before the bound cannot hold a message after it, so it is skipped unparsed.
Over this repo's own project, `messages` took 1.12s and `messages --since 1day` 0.077s.
`--until` gets no such shortcut — a file written today may have started months ago — so it filters rows after parsing.

### `claude-nu export-session`

Export session dialogue to markdown.

```nushell no-run
claude-nu export-session                    # Uses session summary as title
claude-nu export-session "Auth refactor"    # Custom title, used as given
claude-nu sessions --session <uuid> | claude-nu export-session # Specific session
claude-nu export-session | save session.md  # Saving is the shell's job
```

The output is the markdown itself — one string per session, with the session id and date in the YAML frontmatter.
Saving is ordinary `save`, not a flag.

Filters out system-generated messages, keeping only user prompts and assistant responses.

### `claude-nu project-move`

Point Claude Code's stored state at a project's new location.
Claude keys everything by the absolute project path, so a directory you moved with `mv` leaves its sessions, its permissions and its prompt history stranded under the old name — `claude --resume` in the new place finds nothing.
Both arguments are real paths on disk, not encoded directory names.

```nushell no-run
claude-nu project-move ~/old/proj ~/new/proj --dry-run # report what would change, write nothing
claude-nu project-move ~/old/proj ~/new/proj           # do it
```

It rewrites the four places the path is written, and only those: the sessions directory name under `~/.claude/projects`, the `cwd` field in every session record (subagent transcripts included), every mention of the path as a whole quoted string in `~/.claude.json` — its `projects` key and its `githubRepoPaths` entry — and the `project` field in `~/.claude/history.jsonl`.
One row per artifact touched comes back, with the number of occurrences replaced; `--dry-run` returns the same rows.

It refuses to merge two projects into one: if Claude already has a sessions directory for the new path, or `~/.claude.json` carries the old path and the new one at once, the move stops.
The config check is not cosmetic — the swap is textual, so rewriting the old key when the new one is already there would leave `projects` holding the same key twice, JSON a parser still reads while one project's permissions quietly win.
Only the old path and the new one *together* mean a merge: the new path alone is what a run leaves behind when it dies after the config swap, and a rerun has to finish that move rather than call it a collision.

It also refuses to rename a sessions directory that two projects share.
The encoded name is lossy — `/work/demo` and `/work-demo` both become `-work-demo` — and the rename takes the whole directory, so the other project's transcripts would land under the new name while everything that points at them still says the old path.
When a transcript under the source directory records some other path, the move stops and names the file and the path it found.
A transcript recording the new path is a half-finished rerun, and one recording no path at all is a session that died before its first turn — neither is a second project, and neither stops the move.

**What it does not touch.**
The project directory itself — move that yourself, this command only fixes what Claude wrote about it.
And the old path where it appears inside message texts and tool arguments: those record what happened at the old location, and rewriting them would falsify the transcript.
Projects nested under the old path (git worktrees, for instance) are separate projects with their own state; move each one.

**Why a literal substring swap and not a JSON round trip.**
A session record is a line of JSON we did not author.
Parsing and re-emitting it rewrites every byte of every record — escaping, key order, how numbers are spelled — in order to change one field.
Swapping the exact fragment `"cwd":"<old>"` touches only the bytes that encode the path.
Measured on one real 62-line session: the path occurs 65 times, 45 of them as that fragment.

**Failure behaviour.**
Each file is written through a temp file beside it — seeded by copying the target, so a 0600 `~/.claude.json` does not come back 0644 through the umask — and the rename of the sessions directory comes last.
A run that dies partway therefore leaves the sessions under the old name with some `cwd`s already rewritten, and running the same command again finishes exactly what is left: a file already done reports no occurrences and drops out of the next plan.
That holds at every point of the run, including after the config swap — the last write before the rename — which is why a `~/.claude.json` carrying only the new path is read as unfinished work and not as a second project to merge.
Because `~/.claude.json` is rewritten whole by every running `claude`, its mtime is checked between read and write, turning a lost concurrent save into an error instead of silence.
A session file whose bytes are not valid UTF-8 stops the move before anything is written, rather than being skipped in silence.

### `claude-nu gi`

Set up the gi protocol in a repo — where all "what/why" lives in git (the diff and commit body) and the chat carries almost nothing.
It comes in three verbs.
`enable` **seeds** the repo: the Canvas output style and the gi skills.
`import` **writes a canvas** from a session's dialogue.
`open` **launches** a session bound to one canvas, creating the canvas if it does not exist yet — that launch is the only thing that turns gi on.

Each verb is a real Nushell subcommand, so it carries its own flags and its own `help claude-nu gi <verb>`, and `claude-nu gi <TAB>` completes them.

```nushell no-run
claude-nu gi enable            # seed style + skills into this repo (no canvas); optional — `gi open` seeds for itself
claude-nu gi enable --no-gitignore # ...leaving the seeds visible to git, to commit them for a teammate
claude-nu gi import            # a canvas from the dialogue of the session this runs inside (gi/session-<id>.md)
claude-nu gi import <TAB>      # ...or of any session: the picker shows age, size, summary
claude-nu gi import --to notes/x.md # ...at a chosen path
claude-nu gi import --tools    # ...keeping tool calls as one-line placeholders
claude-nu gi import --commit   # ...and commit it
claude-nu gi import --gitignore # ...or keep it out of git
claude-nu gi open              # new canvas + a session bound to it
claude-nu gi open gi/plan.md   # ...a named one: created from the template if new, resumed if it already holds a session
claude-nu gi open gi/plan.md --no-hook # style only, without the Stop-hook floor
claude-nu gi open gi/plan.md --new-session # start over on it: mint a fresh id, overwrite the recorded one
claude-nu gi open gi/plan.md --fork # ...or keep it as it is and open a copy (gi/plan_1.md) on a session of its own
claude-nu gi open gi/plan.md --dangerously-skip-permissions --model opus # ...any other flag goes straight to `claude`
claude-nu gi                   # { canvas, style, skills, stale }
```

**The Stop hook** is the hard floor that comes with every bound session: the agent's final chat message must stay small — `done`, a status note, a pointer to where the answer landed — at most 3 line breaks and 480 characters; anything bigger blocks the turn with an instruction to move the answer into the canvas and commit it — the block message names the exact file.
Size is the whole rule: no path is required, because demanding one made a short honest status note ("waiting on the background agent") a violation, which taught the agent to invent a path rather than to write less.
It also blocks any turn ending on `main`/`master`: gi commits are internal working history; they reach a public branch only squash-merged, after finalization.
The character budget is tunable via `GI_HOOK_MAX_LEN`.

**`chat:` is the way out.**
Open your message with `chat:` and that one exchange is off the canvas: the hook lets the turn end with any answer, on any branch, and the style tells the agent to answer in chat and write nothing — no document, no commit.
It is for the questions you ask *about* the work rather than as part of it.
The marker is read from the transcript, from your last authored message, so only you can spend one: a marker the agent could write would be the agent lifting its own floor, which is what the hook exists to prevent.
It covers one turn — the next unmarked message is canvas work again.

**Why activation lives at launch.**
`gi open` passes the style and the hook to `claude --settings` (which takes inline JSON, merges with the project's settings rather than replacing them), names the canvas to the agent with `--append-system-prompt`, and sets `$env.GI_CANVAS` in the launch environment, which the hook inherits as a child process.
The path goes to the agent as text and to the hook as an environment variable because an environment variable is not in the model's context: pointing the agent at `$env.GI_CANVAS` cost a shell call per session, and when the agent misremembered the variable's name it read an empty string and started listing directories to find a canvas.
So gi writes to no settings file at all, and there is nothing to switch off afterwards: a plain `claude` in a seeded repo is a plain session, always.
The earlier design put `outputStyle`, the hook, and the canvas path into `.claude/settings.local.json` — repo-wide keys that loaded into *every* session opened there, so a canvas from last week kept shaping unrelated work until you remembered to disable it.
`$env.GI_CANVAS` is also the hook's on/off switch: with no canvas bound it has nothing to enforce and stands down.

A repo can hold as many canvases as you like — each `gi open` binds one session to one file, so parallel canvases never collide.

**One directory.**
gi runs where you are standing: a relative canvas path is read against your cwd, the session starts there, and the path gi prints, hands to the agent, and quotes in a hook message is relative to the same place — so what you read is what you can paste back.
`--root <dir>` moves the whole run there instead.
Only two things stay repo-scoped, because they are properties of the repo and not of the canvas: `.claude/` is seeded at the git root, and the branch guard reads the repo's branch.
Anchoring the canvas at the git root as well is what this replaced, and inside a monorepo it silently wrote to the wrong file: run from `mono/sub`, `gi open todo/x.md` made and bound `mono/todo/x.md` — a second file with the same name as the one you meant.
One consequence to know: a canvas opened from a subdirectory gets its own session store, so `claude-nu sessions` at the repo root needs `--all-projects` to list it.

**Your own `claude` flags.**
`gi open` is `--wrapped`: anything it does not define is forwarded to `claude` untouched, so `--dangerously-skip-permissions`, `--model`, `--append-system-prompt` and the rest work as usual.
Two rules keep the binding honest.
Flags gi sets itself — `--settings`, `--session-id`, `--resume`/`-r`, `--continue`/`-c`, `--fork-session`, `--name`, short forms included — are refused, because a second `--settings` wins over gi's and would carry off the style and the Stop hook, leaving gi silently half on.
And a flag typed where the canvas goes (`gi open --model opus`) is refused too: nushell hands an undeclared leading flag to the positional, so it would otherwise create a canvas named `--model`.
`--dangerously-skip-permissions` is in the signature for that reason — it is the flag most often typed with no canvas named, and being declared it parses in either position.

**One canvas, one session, for life.**
On a canvas with no `session:` in its frontmatter, `gi open` mints the session id itself (`claude --session-id`) and writes it in; on one that already has it, the same command resumes that session (`claude --resume`).
So the same file reopens into the same conversation days later — a canvas is a working document, not a one-sitting scratchpad — and there is no second verb to pick, because the file already says which case it is.
`--new-session` is the way out when that session is gone — deleted, expired, or simply not worth continuing: it mints a fresh id and overwrites the one the canvas records, naming the id it drops as it goes.
The launch also passes `--name <canvas>`, which puts the canvas in the prompt box, the `/resume` picker, and the terminal title, so a window says which canvas it belongs to.

**Forking a canvas.**
`--fork` is the other way out of "one canvas, one session", and the opposite of `--new-session`: instead of overwriting the id the canvas records, it copies the file to the next free name in its series — `plan.md` → `plan_1.md`, a fork of `plan_1.md` → `plan_2.md` — and opens the copy on a session of its own.
The source keeps its session and stays readable.
The use it exists for: plan a change in one conversation, then implement it in a fresh context that starts from the plan — with the conversation that produced the plan still there to consult, and its own canvas still bound to it.
The name carries the lineage, so nothing has to be recorded in the frontmatter.
Numbering is max+1 over the series, never the first free gap: `gi/` is untracked by default, so a deleted `plan_1.md` may still be named in a commit body or a chat pointer, and must not be handed to a different canvas later.
`--fork` needs a canvas to fork from (the positional names the source, not the file being created), and cannot be combined with `--new-session` — both mint an id, but on different files.

**Switching into gi mid-chat:** `gi import` starts the canvas from a session's dialogue instead of the empty template, so the discussion that led you to gi is the canvas's first content.
With no session named it takes the one it runs inside (`$env.CLAUDE_CODE_SESSION_ID` — not "the newest session file", which during a live session is as likely a subagent transcript); name one — with a completer showing age, size and summary — to import an older chat from the REPL, where there is no live session to fall back on.
It keeps user messages and Claude's visible replies, and drops tool calls and thinking behind a note pointing at the raw `.jsonl` (`--tools` keeps tool calls as one-line placeholders — useful when the session's value is in what was tried, not only what was said).
Importing the live session, the turn that runs the import is never in it: Claude Code writes the session log as the turn runs, so the last exchange is still missing.
The doc is named for the session (`gi/session-<id>.md`, or `--to <path>`) and is never overwritten — delete it to re-import.
It lands in the working tree untracked; `--commit` puts it in git, `--gitignore` keeps it out (they are mutually exclusive).
Neither is the default: a transcript carries raw paths and whatever the dialogue quoted, so tracking it is your call — but leaving it ignored means every later gi turn stays out of git too, which is the failure gi exists to prevent.

An imported canvas records the session it came from, so `gi open <doc>` reopens **that same session** (`claude --resume`, so the id keeps matching the frontmatter) with the canvas bound, and — when it was the live session — the agent still holds the turns the log could not contain yet and can append that missing tail itself.
The `gi-canvas` skill drives the whole flow from inside a chat session, so you don't type nushell into Bash: it runs the import and hands you the one line to run.

**`enable` is optional.**
`gi open` needs the Canvas style on disk — `--settings` names a style, and Claude Code resolves it against every `.claude/output-styles/` between the launch directory and the repository root — so it seeds the style and the skills itself at the repo root, copy-if-absent, instead of refusing to launch without them.
One seed serves the whole repo, including a launch from a subdirectory.
That removes an error rather than reordering around one: the style check used to sit *after* `--fork` had already copied a canvas, so a launch that would not start still left a stray file behind and burned a name in the `_n` series.
What `gi enable` still owns is `--force` (refreshing seeds after a module update — a launch must never clobber a style you edited) and the chicken-and-egg of running `gi import` from inside a live session, which needs the `gi-canvas` skill already in the repo but launches nothing, so it never passes through `open`.

**The seeds hide themselves.**
Seeding drops six files into `.claude/`, and an untracked directory is reported by git as a whole — in lazygit it lands as the first expanded folder, burying the changes you actually want to read.
So seeding also writes `.claude/.gitignore` listing the seeds *by exact path*.
Never `*` or a bare `skills/`: gi seeds into `.claude/` but does not own it, and a directory pattern would silently hide a skill you wrote by hand.
gi owns a marked block inside the file: what is between the markers is regenerated from the same list the copy loop uses, so a skill added to the module can never be left unignored, and every line outside them is carried through untouched — `.claude/` is shared, and a line gi did not write is not gi's to delete.
It deliberately does not list itself — `git status` then reports `?? .claude/` as a single line pointing at that one file, which is the state to aim at: the folder still says gi wrote there, and the seeds inside are quiet.
Hiding the ignore file too would make `.claude/` vanish, and an invisible folder is how you forget a tool is writing into your repo.
`gi enable --no-gitignore` skips it, for the repo that wants the seeds committed so a teammate gets gi on clone; `gi open` has no such flag, because it is the verb that seeds a repo which never ran `enable`, and that repo would get the noise back.
Declining is a one-time state anyway — `git add` the seeds and the ignore file stops applying to them, since ignore rules never apply to tracked files.

**Why `import` is its own verb.**
It was `gi enable --from-session`, which put a canvas-writing switch on the one command that makes no canvases, and dragged in a path plus three flags that meant nothing without it — enforced by run-time guards a signature states for free.
As a switch it could also only ever mean the live session, so an older chat could not be imported from the REPL at all, and there was nothing for a completer to complete.

`enable` seeds the **Canvas** output style (the proactive half — the hook is the reactive floor) as `.claude/output-styles/canvas.md`, and the gi skills into `.claude/skills/`.
That is all it writes: canvases come from `gi open`, which creates one from the template and binds a session to it in the same breath, or from `gi import`, which writes one from a dialogue — so no two verbs ever write the same file.
Seeded files are never overwritten, so your edits are safe; `--force` refreshes the style and skills from the module, and `status.stale` lists seeds that have drifted from it.
Drift is also reported where you meet it: `enable`, `import`, and every `gi open` launch print a note naming the seeds that differ, because copy-if-absent pins a repo to whatever the module held when it was first seeded and nobody polls status.
A note, not an error — the seeded copy still works, and the difference may be your own edit, which `--force` would discard.

### `claude-nu example`

Pick a pipeline from the menu and it lands in your command line, ready to read, edit and run.
You run it — the command only writes the buffer, with `commandline edit --replace`.

```nushell no-run
claude-nu example                    # The examples as a table: slug, description, pipeline
claude-nu example <TAB>              # ...as a menu, each slug next to the pipeline it stands for
claude-nu example search-every-project # Paste that one into the command line
```

There is no second list to keep in sync: the rows are the `@example` attributes the module's own commands already carry, read at runtime from `scope commands`.
Examples that cross commands — most pipelines do — hang on the module's `main`, the one place that covers all of them.
`dotnu examples-update` runs those blocks and writes the real output back into `--result`, so a pipeline broken by a rename is caught at authoring time instead of being suggested here.

Slugs come from the description, so they read as labels rather than as indexes.
The menu is not sorted: it keeps the order the code declares — the module's own pipelines first, then each command's — because that order is authored, while alphabetical would follow whatever word a description happens to start with.
The menu is REPL-only where it pastes: `commandline edit` has no buffer to write to in a script, which is why the bare form returns the table instead.

## CLI Completions

Two completion files live here, for the two CLIs this repo is actually about.
Add either to your `config.nu`:

```nushell no-run
use completions/claude.nu *
use completions/nu.nu *
```

- `completions/claude.nu` — `claude`: 50+ flags, MCP/plugin subcommands, session picker for `--resume`
- `completions/nu.nu` — `nu`: Parses .nu scripts at tab-time to offer their subcommands and flags

Completions for unrelated tools (`zellij`, `fd`, `chafa`, `sandbox-exec`) used to live here too.
They moved to the dotfiles repo, under `nushell/completions/`, which is where per-tool shell integration belongs.

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

- `nushell-completions` — Teaches Claude Code to write Nushell completions: inline lists, custom completers, `extern` definitions, module naming rules.
  Point it at `--help` output and it produces a ready-to-use completion file.
- `nushell-style` — Opinionated Nushell style guide: pipeline patterns, command choices, formatting conventions, testing patterns.
  Activates automatically when editing `.nu` files.

All completions in this repo were built with the `nushell-completions` skill.

## How it works

Claude Code stores session data as JSONL files in `~/.claude/projects/<encoded-path>/`.
Each file contains:
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
