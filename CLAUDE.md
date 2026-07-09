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
│   └── gi-hook.nu       # gi-hook Stop hook (enable/disable/status/check)
├── completions/         # External command completions
│   ├── claude.nu        # claude CLI (50+ flags, session picker, MCP/plugin subcommands)
│   ├── nu.nu            # nu CLI (dynamic: parses scripts for subcommands at tab-time)
│   ├── zellij.nu        # zellij (100+ actions, live session completers)
│   ├── chafa.nu         # chafa image viewer (35+ completers)
│   └── sandbox-exec.nu  # macOS sandbox-exec
├── tests/               # 60+ tests (nutest framework)
├── toolkit.nu           # Dev tools: test, fetch-docs, vendor-sessions, check
├── ../claude-code-docs/    # Downloaded Claude Code documentation (60+ pages)
└── ../nushell-docs/        # Sparse clone of Nushell docs (book, cookbook, blog)
```

**Key concepts:**
- Session files: JSONL in `~/.claude/projects/<encoded-path>/` where path is `-` separated segments
- `sessions` uses lazy evaluation — 25+ optional columns, only requested extractions run
- `nu.nu` completions dynamically parse script AST to discover subcommands at tab-time
- `claude.nu` session picker shows age, size, and summary alongside UUIDs
- `claude-nu/gi-md-src/canvas-output-style.md` is the canonical Canvas style; `gi-hook enable` seeds it into each repo's `.claude/output-styles/canvas.md`. A public copy lives in `../my-claude-skills/plugins/canvas-output-style/output-styles/canvas.md` — edit here first, then sync there. That copy deliberately drops the `$env.GI_HOOK_DOC` sentence (no hook there to set it) and the protected-branch bullet (it names a skill the plugin doesn't ship). Keep the style file itself comment-free: it is seeded verbatim and injected into every consumer session's system prompt.

## Commands

```nushell
# Setup in config.nu
use /path/to/claude-nu
use /path/to/completions/claude.nu *
use /path/to/completions/nu.nu *

# Core commands
claude-nu -f 'regex'                   # Search this project's user messages (shorthand for the sessions|where|messages idiom below)
claude-nu -f 'regex' --all-projects    # Same search across every project
claude-nu projects                     # Projects by recency (name, path, count, modified)
claude-nu projects | where name =~ nu | claude-nu sessions | claude-nu messages # pipe chain scoping
claude-nu messages                     # User messages from current session
claude-nu sessions | claude-nu messages 'regex' # search all sessions in project
claude-nu sessions --all-projects | claude-nu messages 'regex' # search across all projects
claude-nu sessions | claude-nu messages 'regex' | claude-nu messages --include-responses # full dialogues of matched sessions
claude-nu sessions | claude-nu messages 'regex' | claude-nu export-session | claude-nu save-markdown # export matched sessions to markdown
claude-nu sessions                     # Top-level (human) sessions with summaries and stats
claude-nu sessions --subagents         # Also include subagent transcripts (parent_session_id set)
claude-nu sessions --all-columns       # 25+ fields: tools, errors, agents, thinking level...
claude-nu sessions --last --columns token_usage,turn_count # Comma-separated columns, most recent session
claude-nu export-session               # Export to markdown with YAML frontmatter
claude-nu gi-hook enable               # Install a per-repo Stop hook that keeps chat terse (gi protocol)
claude-nu gi-hook enable notes/plan.md # Same, with a chosen working-doc path (default: gi/canvas-<timestamp>.md)
claude-nu gi-hook enable --force       # Re-seed the style and skills from the module (working doc untouched)
claude-nu gi-hook status               # { enabled, settings, doc, style, skills, stale, output_style_set }
```

## Development

Uses [nutest](https://github.com/vyadh/nutest) framework (expected at `../nutest`).

Output mode is auto-detected via `is-terminal --stdout` (not `$nu.is-interactive`, which is false for any `nu toolkit.nu ...` script run and so can't tell agent from human): a terminal gets the human view — only the failing tests plus a `N passed, M failed` summary — while a pipe or redirect (agents, CI) gets machine-readable JSON with the flat schema `{type, name, status, file, message}` (`message` holds the assertion text on failure). Force with `--json` / `--pretty`; `--all` also lists passing tests.

```nushell
nu toolkit.nu test                     # Run all tests (60+ cases)
nu toolkit.nu test --fail              # Exit non-zero on failures (for CI)
nu toolkit.nu test --json              # Force JSON on a terminal; --pretty forces human view when piped
nu toolkit.nu check                    # Static syntax checking with diagnostics

# Documentation management
nu toolkit.nu fetch-claude-docs        # Download Claude Code docs (sitemap-based, parallel)
nu toolkit.nu fetch-nushell-docs       # Sparse clone of Nushell docs

# Test fixtures
nu toolkit.nu vendor-sessions         # Obfuscate real sessions for safe sharing
```

## Code Style

Follow the nushell-style skill (install via `/plugin install nushell-style@nushell-skills`). Key patterns:

- Leading `|` on continuation lines, aligned with `let`
- Empty `{ }` for pass-through branches: `| if $cond { } else { transform }`
- Use `where` for filtering (not `each {if} | compact`)
- Include type signatures: `]: nothing -> table {`
- Use `match` for type dispatch, `scan` for stateful transforms
