# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-nu is a Nushell module providing utilities for working with Claude Code sessions and CLI completions. Work in progress — features added as needed.

## Architecture

```
claude-nu/
├── claude-nu/           # Main module
│   ├── mod.nu           # Module entry point, exports public commands
│   └── commands.nu      # Command implementations
├── completions/         # External command completions
│   ├── claude.nu        # claude CLI (50+ flags, session picker, MCP/plugin subcommands)
│   ├── nu.nu            # nu CLI (dynamic: parses scripts for subcommands at tab-time)
│   ├── zellij.nu        # zellij (100+ actions, live session completers)
│   ├── chafa.nu         # chafa image viewer (35+ completers)
│   └── sandbox-exec.nu  # macOS sandbox-exec
├── skills/              # Vendored Claude Code skills (managed via toolkit)
│   ├── nushell-style/   # Nushell code style guide with 6 reference docs
│   └── nushell-completions/  # Completions implementation patterns
├── tests/               # 60+ tests (nutest framework)
├── toolkit.nu           # Dev tools: test, fetch-docs, vendor-skills, vendor-sessions, check
├── claude-code-docs/    # Downloaded Claude Code documentation (60+ pages)
└── nushell-docs/        # Sparse clone of Nushell docs (book, cookbook, blog)
```

**Key concepts:**
- Session files: JSONL in `~/.claude/projects/<encoded-path>/` where path is `-` separated segments
- `parse-session` uses lazy evaluation — 25+ optional columns, only requested extractions run
- `nu.nu` completions dynamically parse script AST to discover subcommands at tab-time
- `claude.nu` session picker shows age, size, and summary alongside UUIDs

## Commands

```nushell
# Setup in config.nu
use /path/to/claude-nu
use /path/to/completions/claude.nu *
use /path/to/completions/nu.nu *

# Core commands
claude-nu messages                     # User messages from current session
claude-nu messages 'regex' -a          # Search across all sessions in project
claude-nu messages --all-projects      # Search across all projects
claude-nu sessions                     # All sessions with summaries and stats
claude-nu parse-session --all          # 25+ fields: tools, errors, agents, thinking level...
claude-nu export-session               # Export to markdown with YAML frontmatter
```

## Development

Uses [nutest](https://github.com/vyadh/nutest) framework (expected at `../nutest`).

```nushell
nu toolkit.nu test                     # Run all tests (60+ cases)
nu toolkit.nu test --fail              # Exit non-zero on failures (for CI)
nu toolkit.nu check                    # Static syntax checking with diagnostics

# Documentation management
nu toolkit.nu fetch-claude-docs        # Download Claude Code docs (sitemap-based, parallel)
nu toolkit.nu fetch-nushell-docs       # Sparse clone of Nushell docs

# Skills management (skills/ ↔ ~/.claude/skills)
nu toolkit.nu vendor-skills            # Copy from ~/.claude/skills to repo
nu toolkit.nu install-skills-globally  # Copy from repo to ~/.claude/skills

# Test fixtures
nu toolkit.nu vendor-sessions         # Obfuscate real sessions for safe sharing
```

## Code Style

Follow the nushell-style skill (`~/.claude/skills/nushell-style`). Key patterns:

- Leading `|` on continuation lines, aligned with `let`
- Empty `{ }` for pass-through branches: `| if $cond { } else { transform }`
- Use `where` for filtering (not `each {if} | compact`)
- Include type signatures: `]: nothing -> table {`
- Use `match` for type dispatch, `scan` for stateful transforms
