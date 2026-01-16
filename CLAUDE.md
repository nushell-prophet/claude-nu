# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

claude-nu is a Nushell module providing utilities for working with Claude Code sessions and CLI completions.

## Architecture

```
claude-nu/
├── claude-nu/           # Main module
│   ├── mod.nu           # Module entry point, exports public commands
│   └── commands.nu      # Command implementations (messages, completions)
├── completions/
│   └── claude.nu        # Nushell completions for `claude` CLI
├── tests/               # Unit tests (nutest framework)
│   └── test_commands.nu # Tests for command logic
├── toolkit.nu           # Development tools (test, fetch-claude-docs)
└── claude-code-docs/    # Downloaded Claude Code documentation (reference)
```

**Key components:**
- `messages` command: Extracts user messages from Claude Code session files (JSONL in `~/.claude/projects/<path>/`)
- `completions/claude.nu`: External command completions for the `claude` CLI with all flags and subcommands
- Session files are per-project, path encoded as `-` separated segments

## Usage

```nushell
# Add to config.nu
use /path/to/claude-nu
source /path/to/completions/claude.nu

# Commands
claude-nu messages              # Get user messages from current session
claude-nu messages 'pattern'    # Filter by regex
claude-nu messages --raw        # Get raw JSONL records
claude-nu messages --all        # Include system messages
```

## Testing

Uses [nutest](https://github.com/vyadh/nutest) framework (expected at `../nutest`).

```nushell
nu toolkit.nu test          # Run all tests
nu toolkit.nu test --json   # Output JSON for CI
nu toolkit.nu test --fail   # Exit non-zero on failures (for CI)
```

Test files use `@test` decorator and live in `tests/` directory.

## Code Style

Follow the nushell-style skill (`~/.claude/skills/nushell-style`). Key patterns:

- Leading `|` on continuation lines, aligned with `let`
- Empty `{ }` for pass-through branches: `| if $cond { } else { transform }`
- Use `where` for filtering (not `each {if} | compact`)
- Include type signatures: `]: nothing -> table {`
- Use `match` for type dispatch, `scan` for stateful transforms
