# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

nu-claude is a Nushell module providing utilities for working with Claude Code sessions and CLI completions.

## Architecture

```
nu-claude/
├── nu-claude/           # Main module
│   ├── mod.nu           # Module entry point, exports public commands
│   └── commands.nu      # Command implementations (messages, completions)
├── completions/
│   └── claude.nu        # Nushell completions for `claude` CLI
├── toolkit.nu           # Development tools (fetch-claude-docs)
└── claude-code-docs/    # Downloaded Claude Code documentation (reference)
```

**Key components:**
- `messages` command: Extracts user messages from Claude Code session files (JSONL in `~/.claude/projects/<path>/`)
- `completions/claude.nu`: External command completions for the `claude` CLI with all flags and subcommands
- Session files are per-project, path encoded as `-` separated segments

## Usage

```nushell
# Add to config.nu
use /path/to/nu-claude
source /path/to/completions/claude.nu

# Commands
nu-claude messages              # Get user messages from current session
nu-claude messages 'pattern'    # Filter by regex
nu-claude messages --raw        # Get raw JSONL records
nu-claude messages --all        # Include system messages
```

## Code Style

Follow the nushell-style skill (`~/.claude/skills/nushell-style`). Key patterns:

- Leading `|` on continuation lines, aligned with `let`
- Empty `{ }` for pass-through branches: `| if $cond { } else { transform }`
- Use `where` for filtering (not `each {if} | compact`)
- Include type signatures: `]: nothing -> table {`
- Use `match` for type dispatch, `scan` for stateful transforms
