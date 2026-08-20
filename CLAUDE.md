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
│   ├── sessions.nu      # User-facing session/message commands; re-exports the submodules below
│   ├── discovery.nu     # On-disk session layout: enumerate, resolve, read session files
│   ├── extract.nu       # Session records -> text, dialogue, metrics
│   ├── render.nu        # Record content -> markdown text
│   ├── gi.nu            # gi protocol, as real subcommands (`gi enable`, `gi import`, `gi open`, bare `gi` for status): enable seeds the repo, import writes a canvas from a session's dialogue, open launches a session bound to one canvas (style + Stop hook travel with the launch)
│   ├── project-move.nu  # Retarget stored state from a project's old path to its new one
│   ├── ask.nu           # One-shot `claude --print` prompt; not re-exported by mod.nu — `use claude-nu/ask.nu *`
│   ├── gi-md-src/       # Sources gi enable seeds into a repo: canvas-header.md, canvas-output-style.md, skills/
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
- `nu.nu` completions dynamically parse script AST to discover subcommands at tab-time
- `claude.nu` session picker shows age, size, and summary alongside UUIDs
- `claude-nu/gi-md-src/canvas-output-style.md` is the canonical Canvas style; `gi enable` seeds it into each repo's `.claude/output-styles/canvas.md`, and `gi open` turns it on for one launch via `claude --settings`.
  A public copy lives in `../my-claude-skills/plugins/canvas-output-style/output-styles/canvas.md` — edit here first, then sync there.
  That copy deliberately drops the sentence about the canvas path arriving with the launch (nothing launches it there) and the protected-branch bullet (it names a skill the plugin doesn't ship).
  Keep the style file itself comment-free: it is seeded verbatim and injected into every consumer session's system prompt.
- The `chat:` aside has two halves that must stay in sync: `gi-off-canvas` in `gi.nu` (the hook reads the marker from the transcript's last authored user message and lets the turn end — message rule and branch guard both) and the matching bullet in the style (answer in chat, write nothing).
  The marker is only ever the user's: an agent-written one would be the agent lifting its own floor.
- `gi enable` seeds only distributed text — the style and the skills — and is not a prerequisite for `gi open`, which seeds the same files itself (`gi-seed`, copy-if-absent) rather than refusing to launch without them.
  What `enable` still owns: `--force`, `--no-gitignore`, and getting the `gi-canvas` skill into a repo where the work starts inside a live session (that path launches nothing, so it never reaches `open`).
  Seeding also writes `.claude/.gitignore` (`gi-ignore-text`): exact paths, never `*` or a bare `skills/` — gi seeds into `.claude/` but does not own it — inside a marked block that is regenerated every run while lines outside it survive, and deliberately not listing itself, so `git status` keeps one `?? .claude/` line instead of the folder vanishing.
  Canvases come from the other two verbs: `gi open <doc>` creates one from `gi-md-src/canvas-header.md` and stamps the session it mints into its frontmatter, `gi import` writes one from a session's dialogue (export-session stamps the frontmatter there) — so no two verbs ever write the same file.
- `gi import` is the only verb runnable from inside the session being captured: `enable` makes no canvas and `open` launches `claude`, which a live session cannot do for itself.
  Its session is a parameter with the `nu-complete claude sessions` picker, not a switch — a switch could only mean the live session, so the REPL case (import an older chat) had no spelling at all.
- gi runs in one directory and every path is relative to it: `gi-run-dir` is `--root` when given, otherwise your cwd.
  The launch `cd`s there, a relative canvas is read there, and the one short form (`gi-doc-path`'s `rel`) — printed, pasted back as a command, handed to the agent, and used by the hook — is relative to it.
  `root` stays a separate value for the two repo-scoped things: seeding `.claude/` and the branch guard.
  Anchoring the canvas at the repo root instead was the bug: inside a monorepo the root is never where you work, so `gi open todo/x.md` from `mono/sub` made and bound `mono/todo/x.md`.
  The `cd` is not needed to find the style — Claude Code loads project output styles from every `.claude/output-styles/` between the working directory and the repository root (`../claude-code-docs/output-styles.md`), so one seed at the root serves every subdirectory.
  Cost accepted: a canvas opened from a subdirectory gets its own session store (`~/.claude/projects/` is keyed by cwd), so `claude-nu sessions` at the root will not list it without `--all-projects`; `claude --resume <id>` finds it anyway, since v2.1.223 searches every project on the machine.
- `claude-nu/gi-md-src/skills/` holds the skills `gi enable` seeds into a repo's `.claude/skills/`.
  `gi-canvas` is the in-session entry point: it runs `gi import` and hands the user the command to launch the bound session, because a session cannot bind itself.

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
claude-nu sessions --session <uuid> | claude-nu messages # One named session — `sessions` is the only place selection lives
claude-nu sessions --all-projects | claude-nu messages 'regex' # search across all projects
claude-nu sessions | claude-nu messages 'regex' | claude-nu messages --include-responses # full dialogues of matched sessions
claude-nu sessions | claude-nu messages 'regex' | claude-nu export-session # markdown of matched sessions in the pipeline (one string per session)
claude-nu sessions                     # Top-level (human) sessions with summaries and stats
claude-nu sessions --subagents         # Also include subagent transcripts (parent_session_id set)
claude-nu sessions --all-columns       # 25+ fields: tools, errors, agents, reasoning effort...
claude-nu sessions --last --columns token_usage,turn_count # Comma-separated columns, most recent session
claude-nu export-session               # Markdown with YAML frontmatter; save is the shell's job: `| save file.md`
claude-nu project-move ~/old ~/new     # Retarget Claude's state after a project directory moved: sessions dir name, `cwd` in every record, ~/.claude.json (`projects` + `githubRepoPaths`), history.jsonl. `--dry-run` reports the same rows without writing. Literal substring swap, never a JSON round trip. A store already standing at the destination is folded into, not refused — a project that moves twice comes back to a name Claude knows. A file in both stores is resolved by containment: transcripts are append-only, so the copy that contains the other wins (`keep-source` / `keep-destination`), and a pair where neither contains the other stops the run before anything is written. Only two `~/.claude.json` project entries are still refused — no rule picks a winner for `allowedTools` or a trust flag, so the error prints the two commands that show both records
claude-nu gi enable                    # Seed the Canvas style and the gi skills into this repo (writes no settings, turns nothing on, makes no canvas). Optional before `gi open`, which seeds for itself
claude-nu gi enable --force            # Re-seed the style and skills from the module
claude-nu gi enable --no-gitignore     # Seed without writing `.claude/.gitignore` — the seeds stay visible to git, to be committed. Only this verb can decline; `gi open` always writes it
claude-nu gi import                    # A canvas from a session's dialogue (gi/session-<id>.md). No session named = the one this runs inside; name any session (completer: age, size, summary) to import an older chat from the REPL
claude-nu gi import --to notes/plan.md # ...at a chosen path (a flag, not a positional: the in-session call names a path but no session)
claude-nu gi import --tools            # ...keeping tool calls as one-line placeholders
claude-nu gi import --commit           # ...and commit it; --gitignore keeps it out of git instead
claude-nu gi open gi/plan.md           # Launch a session bound to that canvas: style + Stop hook via `claude --settings`, the canvas path stated to the agent via `--append-system-prompt` (an env var is not in the model's context, so GI_CANVAS alone left it hunting), $env.GI_CANVAS set for the hook. A canvas with no `session:` gets one minted and written in; one that has it is resumed. Created from the template if new; --no-hook drops the floor; --new-session overwrites the recorded id when that session is gone; --fork instead leaves the canvas bound and opens a copy at the next `_n` sibling (`plan.md` → `plan_1.md`, max+1 over the series) on a session of its own — plan in one conversation, implement in a fresh context; parallel canvases per repo. `--wrapped`: unknown flags (`--model`, ...) go straight to `claude` (`--dangerously-skip-permissions` is not one of them — `gi open` declares it itself, so that it cannot land in the doc's place), except the ones gi sets itself (`--settings`, `--session-id`, `--resume`/`-r`, `--continue`/`-c`, `--fork-session`, `--name`, `--append-system-prompt` — `claude` keeps only the last of two, which would drop the canvas line), and a flag in the doc's place is an error rather than a canvas named `--model`
claude-nu gi                           # { canvas, style, skills, stale } — canvas comes from $env.GI_CANVAS, i.e. the asking session
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
It already holds: of the 187 commits since June, 7 carry Russian, always as a quoted line inside an English body, and none has a Russian subject — which is what keeps `git log --grep` in one language from silently missing part of the history. The README and this file are English anyway.
Translating the reasoning at commit time is the cost; keeping one searchable history is what it buys.

The prefix is the command or subsystem the change is about: `gi:`, `gi-hook:`, `gi-md-src:`, `sessions:`, `messages:`, `ask:`, `export-session:`, `completions:`, `canvas:`, `toolkit:`.
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
