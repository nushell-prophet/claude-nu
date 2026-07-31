# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-nu is a Nushell module providing utilities for working with Claude Code sessions and CLI completions. Work in progress — features added as needed.

The completions are a secondary feature, and more of a historical artifact. The main purpose of this repo is to build convenient Nushell tooling for interacting with Claude's sessions.

Always think about CLI interface usability and ways to benefit from the pipelines architecture. If you see better ways to do what the user requests — mention that.

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
│   ├── gi.nu            # gi protocol, as real subcommands (`gi enable`, `gi open`, bare `gi` for status): enable seeds the repo, open launches a session bound to one canvas (style + Stop hook travel with the launch)
│   ├── project-move.nu  # Retarget stored state from a project's old path to its new one
│   ├── gi-hook.nu       # Stop-hook entry point — `nu --stdin` runs this file; it imports `gi check` from gi.nu, which mod.nu deliberately does not re-export
│   └── attribution.nu   # Claude-authorship of git history: commits (--by-month) and code-authorship (blame)
├── completions/         # External command completions
│   ├── claude.nu        # claude CLI (50+ flags, session picker, MCP/plugin subcommands)
│   ├── nu.nu            # nu CLI (dynamic: parses scripts for subcommands at tab-time)
│   ├── zellij.nu        # zellij (100+ actions, live session completers)
│   ├── chafa.nu         # chafa image viewer (35+ completers)
│   └── sandbox-exec.nu  # macOS sandbox-exec
├── tests/               # 60+ tests (nutest framework)
└── toolkit.nu           # Dev tools: test, vendor-sessions, check
```

Reference-doc fetchers (Claude Code + Nushell docs) moved to cozy: `cozy docs claude` / `cozy docs nushell` (see `../cozy/cozy-module/docs.nu`).

**Key concepts:**
- Session files: JSONL in `~/.claude/projects/<encoded-path>/` where path is `-` separated segments
- `sessions` uses lazy evaluation — 25+ optional columns, only requested extractions run
- `nu.nu` completions dynamically parse script AST to discover subcommands at tab-time
- `claude.nu` session picker shows age, size, and summary alongside UUIDs
- `claude-nu/gi-md-src/canvas-output-style.md` is the canonical Canvas style; `gi enable` seeds it into each repo's `.claude/output-styles/canvas.md`, and `gi open` turns it on for one launch via `claude --settings`. A public copy lives in `../my-claude-skills/plugins/canvas-output-style/output-styles/canvas.md` — edit here first, then sync there. That copy deliberately drops the `$env.GI_CANVAS` sentence (nothing sets it there) and the protected-branch bullet (it names a skill the plugin doesn't ship). Keep the style file itself comment-free: it is seeded verbatim and injected into every consumer session's system prompt.
- `gi enable` seeds only distributed text — the style and the skills. Canvases are the launcher's: `gi open <doc>` creates one from `gi-md-src/canvas-header.md` and stamps the session it mints into its frontmatter, so a canvas is never written by both halves. A path on `enable` only names where `--from-session` puts its import.
- `claude-nu/gi-md-src/skills/` holds the skills `gi enable` seeds into a repo's `.claude/skills/`. `gi-canvas` is the in-session entry point: it runs the import and hands the user the command to launch the bound session, because a session cannot bind itself.

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
claude-nu sessions | claude-nu messages 'regex' | claude-nu export-session --to docs/sessions # export matched sessions to markdown files ({session, filepath} out; no --to = markdown in the pipeline)
claude-nu sessions                     # Top-level (human) sessions with summaries and stats
claude-nu sessions --subagents         # Also include subagent transcripts (parent_session_id set)
claude-nu sessions --all-columns       # 25+ fields: tools, errors, agents, thinking level...
claude-nu sessions --last --columns token_usage,turn_count # Comma-separated columns, most recent session
claude-nu export-session               # Export to markdown with YAML frontmatter; --to <dir> writes the files (save-markdown folded in)
claude-nu project-move ~/old ~/new     # Retarget Claude's state after a project directory moved: sessions dir name, `cwd` in every record, ~/.claude.json (`projects` + `githubRepoPaths`), history.jsonl. `--dry-run` reports the same rows without writing. Literal substring swap, never a JSON round trip
claude-nu commits                      # Per-commit table (sha, date, email, is_claude) for the repo at cwd
claude-nu commits --by-month           # Claude's share of commits per month: { month, total, claude, pct }
claude-nu commits | where is_claude | length # any other cut is a pipeline on the base table
claude-nu code-authorship              # Claude's share of surviving lines (git blame): { total_lines, claude_lines, pct }
claude-nu gi enable                    # Seed the Canvas style and the gi skills into this repo (writes no settings, turns nothing on, makes no canvas)
claude-nu gi enable --force            # Re-seed the style and skills from the module
claude-nu gi enable --from-session     # ...and start a canvas from this session's dialogue (gi/session-<id>.md)
claude-nu gi enable notes/plan.md --from-session # ...at a chosen path
claude-nu gi enable --from-session --tools     # ...keeping tool calls as one-line placeholders
claude-nu gi enable --from-session --commit    # ...and commit it; --gitignore keeps it out of git instead
claude-nu gi open gi/plan.md           # Launch a session bound to that canvas: style + Stop hook via `claude --settings`, $env.GI_CANVAS set. A canvas with no `session:` gets one minted and written in; one that has it is resumed. Created from the template if new; --no-hook drops the floor; --new-session overwrites the recorded id when that session is gone; parallel canvases per repo. `--wrapped`: unknown flags (`--dangerously-skip-permissions`, `--model`, ...) go straight to `claude`, except the ones gi sets itself (`--settings`, `--session-id`, `--resume`, `--continue`, `--fork-session`, `--name`), and a flag in the doc's place is an error rather than a canvas named `--model`
claude-nu gi                           # { canvas, style, skills, stale } — canvas comes from $env.GI_CANVAS, i.e. the asking session
```

## Development

Uses [nutest](https://github.com/vyadh/nutest) framework (expected at `../nutest`).

Output mode is auto-detected via `is-terminal --stdout` (not `$nu.is-interactive`, which is false for any `nu toolkit.nu ...` script run and so can't tell agent from human): a terminal gets the human view — only the failing tests plus a `N passed, M failed` summary — while a pipe or redirect (agents, CI) gets machine-readable JSON with the flat schema `{type, name, status, file, message}` (`message` holds the assertion text on failure). Force with `--json` / `--pretty`; `--all` also lists passing tests.

```nushell
nu toolkit.nu test                     # Run all tests (60+ cases)
nu toolkit.nu test --fail              # Exit non-zero on failures (for CI)
nu toolkit.nu test --json              # Force JSON on a terminal; --pretty forces human view when piped
nu toolkit.nu check                    # Static syntax check of every tracked .nu file
nu toolkit.nu check claude-nu/gi.nu    # ...or of one file; rows carry file, line, severity, message, source

# Test fixtures
nu toolkit.nu vendor-sessions         # Obfuscate real sessions for safe sharing
```

## Commit messages

**English, subject and body — including when the canvas session ran in Russian.** 19 of the 179 commits made since June are Russian and the rest English, so `git log --grep` in either language silently misses part of the history, and the README and this file are English anyway. Translating the reasoning at commit time is the cost; keeping one searchable history is what it buys.

The prefix is the command or subsystem the change is about: `gi:`, `gi-hook:`, `gi-md-src:`, `sessions:`, `messages:`, `ask:`, `export-session:`, `completions:`, `canvas:`, `toolkit:`. Use a conventional type — `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `perf:`, `chore:` — when no single command owns the change.

`gi:` commits that answer a canvas marker keep the canvas's own vocabulary in the body: a `Decision:` line for what was settled, `Why:` for the reasoning, `Propagation:` for what else had to move. That is what makes a canvas answer readable from the log without opening the canvas.

## Code Style

Follow the nushell-style skill (install via `/plugin install nushell-style@nushell-skills`). Key patterns:

- Leading `|` on continuation lines, aligned with `let`
- Empty `{ }` for pass-through branches: `| if $cond { } else { transform }`
- Use `where` for filtering (not `each {if} | compact`)
- Include type signatures: `]: nothing -> table {`
- Use `match` for type dispatch, `scan` for stateful transforms
