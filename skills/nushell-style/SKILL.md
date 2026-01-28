---
name: nushell-style
description: Load this skill when editing, writing, or reviewing any .nu file. Provides idiomatic Nushell patterns, pipeline composition, command choices, and formatting conventions.
---

# Nushell Code Style Guide

## Contents

| File | Topic |
|------|-------|
| **This file** | Quick reference tables, do/don't checklists |
| [patterns.md](patterns.md) | Pipeline composition, command examples, code structure |
| [formatting.md](formatting.md) | Topiary conventions, spacing, declarations |
| [debugging.md](debugging.md) | `--ide-check` for agents, diagnostic parsing |
| [nuon.md](nuon.md) | NUON format, data serialization, config files |
| [testing.md](testing.md) | nutest framework, snapshots, coverage |
| [toolkit.md](toolkit.md) | toolkit.nu, repo utilities, commit conventions |

---

## Agent Tip: Syntax Checking

```nushell
nu --ide-check 10 file.nu | lines | each { from json }
```

Returns structured JSON with error spans. See [debugging.md](debugging.md) for parsing diagnostics.

---

## Command Choices

| Task | Preferred | Avoid |
|------|-----------|-------|
| Filtering | `where` | `filter`, `each {if} \| compact` |
| List filtering | `where $it =~ ...` | `where { $in =~ ... }` |
| Parallel with order | `par-each --keep-order` | `par-each` (when order matters) |
| Pattern dispatch | `match` expression | Long `if/else if` chains |
| Record iteration | `items {\|k v\| ...}` | Manual key extraction |
| Table grouping | `group-by ... --to-table` | Manual grouping |
| Line joining | `str join (char nl)` | `to text` (context dependent) |
| Syntax check (human) | `nu -c 'open file.nu \| nu-check'` | `source file.nu` |
| Syntax check (agent) | `nu --ide-check 10 file.nu` | `nu-check` (unstructured) |
| Membership | `in` operator | Multiple `or` conditions |
| Field extraction | `get --optional` | `each {$in.field?} \| compact` |
| Negation | `$x !~ ...` | `not ($x =~ ...)` |

---

## Pipeline Principles

### Leading `|`
Place `|` at start of continuation lines, aligned with `let`.

### Omit `$in |`
When body starts with pipeline command (`each`, `where`, `select`), input flows automatically.

### Empty `{ }` Pass-Through
Use empty `{ }` for the branch that should pass through unchanged:
- `| if $cond { transform } else { }` — transform when true, pass through when false
- `| if $cond { } else { transform }` — pass through when true, transform when false

### Stateful Transforms
Use `scan` for sequences with state: `use std/iter scan`

→ See [patterns.md](patterns.md) for detailed examples.

---

## Quick Reference

### Do

- Omit `$in |` when command body starts with pipeline command
- Start continuation lines with `|`
- Use empty `else { }` for pass-through
- Use `match` for type dispatch
- Use `in` for membership testing
- Use `get --optional` for field extraction
- Use `scan` for stateful transforms
- Use `where` for filtering
- Use `where $it =~ ...` for list filtering
- Combine consecutive `each` closures when operations can be piped
- Define data first, then filter
- Include type signatures: `]: input -> output {`
- Use `@example` attributes (nutest)
- Use `const` for static data
- Keep custom commands focused
- Export ALL commands from implementation files (enables testing helpers)
- Control public API via `mod.nu` re-exports (not by removing exports)
- Use `par-each --keep-order` for parallel with deterministic output

### Don't

- Start command bodies with `$in |` when a pipeline command follows
- Use spread operator `...` with conditionals (use data-first + `where`)
- Wrap external commands in unnecessary parentheses
- Over-extract helpers for one-time use
- Create wrapper commands that just call an existing command
- Use verbose names for local variables
- Break the pipeline flow unnecessarily
- Remove existing comments (preserve user's context)
- Remove `export` from helpers to "make them private" (use mod.nu instead)

---

## Formatting Summary

- Empty blocks: `{ }` with space
- Closures: `{ expr }` with spaces
- Flags: `--flag (-f)` with space
- Records: multi-line, no trailing comma
- Variables: `let x =` (no `$` on left)

→ See [formatting.md](formatting.md) for full conventions.
