# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-nu is a Nushell module providing utilities for working with Claude Code sessions and CLI completions.

## Architecture

```
claude-nu/
├── claude-nu/           # Main module
│   ├── mod.nu           # Module entry point, exports public commands
│   └── commands.nu      # Command implementations (messages, sessions, parse-session, export-session)
├── completions/         # External command completions
│   ├── claude.nu        # Completions for `claude` CLI
│   └── *.nu             # Other CLI completions
├── skills/              # Vendored Claude Code skills (managed via toolkit)
├── tests/               # Unit tests (nutest framework)
├── toolkit.nu           # Development tools
├── claude-code-docs/    # Downloaded Claude Code documentation
└── nushell-docs/        # Shallow clone of Nushell docs (book, cookbook, blog)
```

**Key concepts:**
- Session files: JSONL in `~/.claude/projects/<encoded-path>/` where path is `-` separated segments
- The `parse-session` command uses lazy evaluation—only requested fields are computed

## Commands

```nushell
# Add to config.nu
use /path/to/claude-nu
use /path/to/completions/claude.nu *

# Core commands
claude-nu messages              # User messages from current session
claude-nu sessions              # All sessions with summaries
claude-nu parse-session --all   # Low-level session parsing
claude-nu export-session        # Export to markdown for git tracking
```

## Development

Uses [nutest](https://github.com/vyadh/nutest) framework (expected at `../nutest`).

```nushell
nu toolkit.nu test              # Run all tests
nu toolkit.nu test --fail       # Exit non-zero on failures (for CI)
nu toolkit.nu test --json       # JSON output

# Documentation management
nu toolkit.nu fetch-claude-docs        # Download Claude Code docs
nu toolkit.nu fetch-nushell-docs       # Sparse clone of Nushell docs

# Skills management (skills/ ↔ ~/.claude/skills)
nu toolkit.nu vendor-skills            # Copy from ~/.claude/skills to repo
nu toolkit.nu install-skills-globally  # Copy from repo to ~/.claude/skills
```

## Code Style

Follow the nushell-style skill (`~/.claude/skills/nushell-style`). Key patterns:

- Leading `|` on continuation lines, aligned with `let`
- Empty `{ }` for pass-through branches: `| if $cond { } else { transform }`
- Use `where` for filtering (not `each {if} | compact`)
- Include type signatures: `]: nothing -> table {`
- Use `match` for type dispatch, `scan` for stateful transforms
