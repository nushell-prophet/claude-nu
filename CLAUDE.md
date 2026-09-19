# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-nu is a Nushell module providing utilities for working with Claude Code sessions and CLI completions.
Work in progress — features added as needed.

The completions are a secondary feature, and more of a historical artifact.
The main purpose of this repo is to build convenient Nushell tooling for interacting with Claude's sessions.

Always think about CLI interface usability and ways to benefit from the pipelines architecture.
If you see better ways to do what the user requests — mention that.

Nushell's completions should be used when they add a real value.

## Architecture

```
claude-nu/
├── claude-nu/           # Main module
│   ├── mod.nu           # Module entry point, exports public commands
│   ├── sessions.nu      # User-facing session/message/tool-call/slash-command commands; re-exports the submodules below
│   ├── discovery.nu     # On-disk session layout: enumerate, resolve, read session files; also the --since/--until bound parsing and the mtime pre-filter
│   ├── extract.nu       # Session records -> text, dialogue, metrics; also the slash-command extractor and the built-in list it filters by
│   ├── render.nu        # Record content -> markdown text
│   ├── gi.nu            # gi protocol, as real subcommands (`gi import`, `gi open`, bare `gi` for status): import writes a canvas from a session's dialogue, open launches a session bound to one canvas (the gi plugin + Stop hook travel with the launch)
│   ├── project-move.nu  # Retarget stored state from a project's old path to its new one
│   ├── ask.nu           # One-shot `claude --print` prompt; not re-exported by mod.nu — `use claude-nu/ask.nu *`
│   ├── example.nu       # `claude-nu example`: the module's own `@example` blocks as a completion menu that pastes the picked pipeline into the command line
│   ├── gi-md-src/       # canvas-header.md (the new-canvas template) and plugin/ — the gi plugin `gi open` hands to `claude --plugin-dir`: .claude-plugin/plugin.json, output-styles/canvas.md, skills/
│   └── gi-hook.nu       # Stop-hook entry point — `nu --stdin` runs this file; it imports `gi check` from gi.nu, which mod.nu deliberately does not re-export
├── completions/         # Completions for the two CLIs this repo is about; unrelated tools moved to ../dotfiles/nushell/completions/
│   ├── claude.nu        # claude CLI (50+ flags, session picker, MCP/plugin subcommands)
│   └── nu.nu            # nu CLI (dynamic: parses scripts for subcommands at tab-time)
├── tests/               # 240+ tests (nutest framework)
└── toolkit.nu           # Dev tools: test, test-unit, vendor-sessions, check, update-captures
```

Reference-doc fetchers (Claude Code + Nushell docs) moved to cozy: `cozy docs claude` / `cozy docs nushell` (see `../cozy/cozy-module/docs.nu`).

**Key concepts:**
- Session files: JSONL in `~/.claude/projects/<encoded-path>/` where path is `-` separated segments
- `sessions` uses lazy evaluation — 25+ optional columns, only requested extractions run
- `tool-calls` is the tool-call half of `messages`: `bash_commands` reads the Bash tool alone, so an invocation an agent made through the nushell MCP server was invisible (82 of 588 when mining this machine for `claude-nu` calls), and the `--columns` path has no rg pre-filter
- `nu.nu` completions dynamically parse script AST to discover subcommands at tab-time
- `claude.nu` session picker shows age, size, and summary alongside UUIDs
- The protocol ships as a plugin: `claude-nu/gi-md-src/plugin/` holds `.claude-plugin/plugin.json` (name `gi`), `output-styles/canvas.md` and `skills/`, and `gi open` hands the directory to `claude --plugin-dir` for that launch alone.
  Nothing is installed and nothing is copied — the plugin is read in place, so it cannot drift from the module and a repo gets no `.claude/` from gi at all.
  Why, and what it replaced: seeding was copy-if-absent, so every repo was pinned to the module text of its first seed and nobody read `status.stale`; one repo ran canvas sessions for two months on a style the module had long since rewritten.
  It also loads only for launches gi makes, so a plain `claude` anywhere is untouched — the property a machine-wide `~/.claude/skills/` install would have lost.
  **Plugin components are namespaced by the plugin name.** The style is `gi:Canvas` (`GI_STYLE`) and the skills are `gi:git-intent`, `gi:git-intent-readback`, `gi:git-intent-distill`, `gi:git-intent-squash-archive`.
  A bare `Canvas` in `outputStyle` resolves to nothing and the session starts style-less **with no error** — verified against the CLI, and the reason `gi-launch-settings` is pinned by its own test.
  So any prose naming a gi skill writes the prefix; the frontmatter `name:` inside each `SKILL.md` does not, since the plugin adds it.
  Keep the style file itself comment-free: it is shipped verbatim and injected into every consumer session's system prompt.
- The `40-gi-canvas` entry-point skill is deliberately **not** in the plugin: it turns a running non-gi chat into a canvas, so it has to exist in sessions gi did not launch, which is exactly where `--plugin-dir` never applies.
  It lives in `../my-claude-skills/plugins/my-skills/skills/40-gi-canvas/`, deployed with that repo's other skills, and it is the one piece of gi that is not read from this module.
- The `chat:` aside has two halves that must stay in sync: `gi-off-canvas` in `gi.nu` (the hook reads the marker from the transcript's last authored user message and lets the turn end — message rule and branch guard both) and the matching bullet in the style (answer in chat, write nothing).
  The marker is only ever the user's: an agent-written one would be the agent lifting its own floor.
- `gi import` is the only verb runnable from inside the session being captured: `open` launches `claude`, which a live session cannot do for itself.
  Its session is a parameter with the `nu-complete claude sessions` picker, not a switch — a switch could only mean the live session, so the REPL case (import an older chat) had no spelling at all.
- gi runs in one directory and every path is relative to it: `gi-run-dir` is `--root` when given, otherwise your cwd.
  The launch `cd`s there, a relative canvas is read there, and the one short form (`gi-doc-path`'s `rel`) — printed, pasted back as a command, handed to the agent, and used by the hook — is relative to it.
  `root` stays a separate value for the one repo-scoped thing left: the branch guard.
  Anchoring the canvas at the repo root instead was the bug: inside a monorepo the root is never where you work, so `gi open todo/x.md` from `mono/sub` made and bound `mono/todo/x.md`.
  The `cd` is not needed to find the style or the skills — `--plugin-dir` names the plugin by absolute path, so no directory the launch stands in changes what loads.
  Cost accepted: a canvas opened from a subdirectory gets its own session store (`~/.claude/projects/` is keyed by cwd), so `claude-nu sessions` at the root will not list it without `--all-projects`; `claude --resume <id>` finds it anyway, since v2.1.223 searches every project on the machine.
- A repo seeded by the old gi keeps its copies until they are deleted by hand, and project skills coexist with plugin skills rather than override them — so a canvas session there loads each gi skill twice, the repo's copy bare and frozen, the plugin's as `gi:*`.
  Four paths to remove: `.claude/output-styles/canvas.md`, `.claude/skills/git-intent*`, `.claude/skills/gi-canvas`, the `# gi seeds` block in `.claude/.gitignore`.
  No code does this: gi no longer reads those paths, so it cannot tell its own leftovers from files the user put there.
- `40-gi-canvas` is the in-session entry point: it runs `gi import` and hands the user the command to launch the bound session, because a session cannot bind itself.

## Commands

```nushell
# Setup in config.nu
use /path/to/claude-nu
use /path/to/completions/claude.nu *
use /path/to/completions/nu.nu *

# Core commands
claude-nu projects                     # Projects by recency (name, path, count, modified)
claude-nu projects | where name =~ nu | claude-nu sessions | claude-nu messages # pipe chain scoping
claude-nu messages                     # Every user message of the current project (empty input = current project)
claude-nu messages 'regex'             # Search this project's user messages (rg pre-scan; --no-rg for exact regex semantics)
claude-nu sessions --last | claude-nu messages # Just the current session
claude-nu sessions --session <uuid|name> | claude-nu messages # One named session, by UUID or the name /rename gave it — `sessions` is the only place selection lives
claude-nu sessions --all-projects | claude-nu messages 'regex' # search across all projects
claude-nu sessions | claude-nu messages 'regex' | claude-nu messages --include-responses # full dialogues of matched sessions
claude-nu sessions | claude-nu messages 'regex' | claude-nu export-session # markdown of matched sessions in the pipeline (one string per session)
claude-nu sessions                     # Top-level (human) sessions with summaries and stats
claude-nu sessions --subagents         # Also include subagent transcripts (parent_session_id set)
claude-nu sessions --all-columns       # 25+ fields: tools, errors, agents, reasoning effort...
claude-nu sessions --last --columns token_usage,turn_count # Comma-separated columns, most recent session
claude-nu sessions --since 1wk         # Sessions active in the last week. `--since`/`--until` are on `sessions`, `messages` and `tool-calls`; each takes a duration meaning ago (`1wk`), a date (`2026-08-01`), or a datetime value. What the window is compared to is the row you asked for: a message or a call by its own timestamp, a session by its file mtime — its last activity. Why that, and what `--since` saves by skipping files unparsed: the README section "The time window"
claude-nu tool-calls                    # Every tool call of the current project: {tool, input, timestamp, session, project, project_name} — what the agent did, as `messages` is what was said
claude-nu tool-calls 'claude-nu sessions' # ...narrowed by a regex over the whole input rendered as NUON (which field holds the string depends on the tool), with the same rg pre-filter and `--no-rg` escape as `messages`. Filtering by tool is a plain `where tool == Bash` — no flag, because unlike the regex it buys no pre-filter
claude-nu sessions --all-projects | claude-nu tool-calls 'npm test' # ...scoped like `messages`, by session rows to the left of the pipe
claude-nu slash-commands | get command | uniq --count | sort-by count --reverse # What you typed, as `messages` is what you said: one row per slash-command invocation {command, args, timestamp, session, project, project_name}, scoped and windowed like `messages`. Built-ins Claude Code handles itself (/clear, /model, /exit ...) are dropped by default and `--all` keeps them; the list is by hand in extract.nu because resolving names against the installed skills would drop every renamed or deleted command, and the record layout tracks the Claude Code version, not the kind. Prompt-skills (/init, /simplify, /code-review) stay counted. A `Skill` tool call is the agent's own choice, not this — that is `tool-calls | where tool == Skill`
claude-nu export-session               # Markdown with YAML frontmatter; save is the shell's job: `| save file.md`
claude-nu export-session --tools       # ...keeping tool calls: a `> [Bash]` header and the whole input record as a fenced NUON block — lossless, reads back with `from nuon`, no per-tool case. Results are the exception and stay a char count: a single `cat` runs to thousands of characters and would bury the dialogue
claude-nu project-move ~/old ~/new     # Retarget Claude's state after a project directory moved: sessions dir name, `cwd` in every record, ~/.claude.json (`projects` + `githubRepoPaths`), history.jsonl. `--dry-run` reports the same rows without writing. Literal substring swap, never a JSON round trip. A store already standing at the destination is folded into, not refused — a project that moves twice comes back to a name Claude knows. A file in both stores is resolved by containment: transcripts are append-only, so the copy that contains the other wins (`keep-source` / `keep-destination`), and a pair where neither contains the other stops the run before anything is written. Only two `~/.claude.json` project entries are still refused — no rule picks a winner for `allowedTools` or a trust flag, so the error prints the two commands that show both records
claude-nu gi import                    # A canvas from a session's dialogue (gi/session-<id>.md). No session named = the one this runs inside; name any session (completer: age, size, summary) to import an older chat from the REPL
claude-nu gi import --to notes/plan.md # ...at a chosen path (a flag, not a positional: the in-session call names a path but no session)
claude-nu gi import --tools            # ...keeping tool calls, each input rendered whole
claude-nu gi import --commit           # ...and commit it; --gitignore keeps it out of git instead
claude-nu gi open gi/plan.md           # Launch a session bound to that canvas: the gi plugin (style + skills, read in place) via `--plugin-dir`, its style name and the Stop hook via `claude --settings`, the canvas path stated to the agent via `--append-system-prompt` (an env var is not in the model's context, so GI_CANVAS alone left it hunting), $env.GI_CANVAS set for the hook. A canvas with no `session:` gets one minted and written in; one that has it is resumed. Created from the template if new; --no-hook drops the floor; --new-session overwrites the recorded id when that session is gone; --fork instead leaves the canvas bound and opens a copy at the next `_n` sibling (`plan.md` → `plan_1.md`, max+1 over the series) on a session of its own — plan in one conversation, implement in a fresh context; parallel canvases per repo. `--wrapped`: unknown flags (`--model`, ...) go straight to `claude` (`--dangerously-skip-permissions` is not one of them — `gi open` declares it itself, so that it cannot land in the doc's place), except the ones gi sets itself (`--settings`, `--session-id`, `--resume`/`-r`, `--continue`/`-c`, `--fork-session`, `--name`, `--append-system-prompt` — `claude` keeps only the last of two, which would drop the canvas line), and a flag in the doc's place is an error rather than a canvas named `--model`
claude-nu gi                           # { canvas, plugin, style, skills } — canvas comes from $env.GI_CANVAS, i.e. the asking session; the rest describe the plugin every launch reads, and there is no `stale` any more because nothing is copied
claude-nu example                      # The `@example` blocks of the loaded claude-nu commands as a table: slug, description, pipeline
claude-nu example <slug>               # ...paste that pipeline into the command line (`commandline edit --replace`), for the user to run. Tab-completes, the menu showing the whole pipeline next to each slug. Source is `scope commands`, not a second list; cross-command pipelines hang on the module's `main`, which no longer spells them out in its help text. The completer returns `{options: {sort: false}, completions: ...}` — the menu order is authored (module pipelines first, then each command's, as declared), not alphabetical
```

## Development

Uses [nutest](https://github.com/vyadh/nutest) framework (expected at `../nutest`).

Output mode is auto-detected via `is-terminal --stdout` (not `$nu.is-interactive`, which is false for any `nu toolkit.nu ...` script run and so can't tell agent from human): a terminal gets the human view — only the failing tests plus a `N passed, M failed` summary — while a pipe or redirect (agents, CI) gets machine-readable JSON with the flat schema `{type, name, status, file, message}` (`message` holds the assertion text on failure).
Force with `--json` / `--pretty`; `--all` also lists passing tests.

```nushell
nu toolkit.nu test                     # Run all tests (240+ cases)
nu toolkit.nu test --fail              # Exit non-zero on failures (for CI)
nu toolkit.nu test --json              # Force JSON on a terminal; --pretty forces human view when piped
nu toolkit.nu check                    # Static syntax check of every tracked .nu file
nu toolkit.nu check claude-nu/gi.nu    # ...or of one file; rows carry file, line, severity, message, source, span

# Test fixtures
nu toolkit.nu vendor-sessions         # Obfuscate real sessions for safe sharing
```

## Commit messages

**English, subject and body — including when the canvas session ran in Russian.**
It already holds: of the 187 commits since June, 7 carry Russian, always as a quoted line inside an English body, and none has a Russian subject — which is what keeps `git log --grep` in one language from silently missing part of the history.
The README and this file are English anyway.
Translating the reasoning at commit time is the cost; keeping one searchable history is what it buys.

The prefix is the command or subsystem the change is about: `gi:`, `gi-hook:`, `gi-md-src:`, `sessions:`, `messages:`, `tool-calls:`, `ask:`, `export-session:`, `completions:`, `canvas:`, `toolkit:`.
Use a conventional type — `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `perf:`, `chore:` — when no single command owns the change.

`gi:` commits that answer a canvas marker keep the canvas's own vocabulary in the body: a `Decision:` line for what was settled, `Why:` for the reasoning, `Propagation:` for what else had to move.
That is what makes a canvas answer readable from the log without opening the canvas.

## Code Style

Follow the nushell-style skill (install via `/plugin install nushell-style@nushell-skills`).
Key patterns:

- Leading `|` on continuation lines, aligned with `let`
- Empty `{ }` for pass-through branches: `| if $cond { } else { transform }`
- Use `where` for filtering (not `each {if} | compact`)
- Include type signatures: `]: nothing -> table {`
- Use `match` for type dispatch, `scan` for stateful transforms
