---
name: nushell-style
description: Nushell code style guide for idiomatic patterns and formatting. Use when writing, reviewing, formatting, or refactoring Nushell (.nu) code. Covers pipelines, command choices, and best practices.
---

# Nushell Code Style Guide

## Chapters

- **This file**: Core style (pipelines, commands, formatting)
- [nuon.md](nuon.md): NUON format, data serialization, config files
- [testing.md](testing.md): nutest, snapshots, coverage
- [toolkit.md](toolkit.md): toolkit.nu, repo utilities, commit conventions

## Pipeline Composition

### Leading Pipe Operator

Place `|` at the start of continuation lines, left-aligned with `let`:

```nushell
# Preferred
let row_type = $file_lines
| each {
    str trim --right
    | if $in =~ '^```' { } else { 'text' }
}
| scan --noinit 'text' {|curr prev| ... }

# Avoid
let row_type = $file_lines | each {
    str trim --right | if $in =~ '^```' { } else { 'text' }
} | scan --noinit 'text' {|curr prev| ... }
```

### Omit Redundant `$in |` Prefix

When a command body starts with a pipeline command (`each`, `where`, `select`, etc.), omit the `$in |` prefix—the input flows automatically:

```nushell
# Preferred: pipeline command receives input directly
export def extract-agents []: table -> table {
    where name? == "Task"
    | each { ... }
}

# Avoid: redundant $in
export def extract-agents []: table -> table {
    $in
    | where name? == "Task"
    | each { ... }
}
```

Note: `$in` IS needed when you must capture the value in a variable:

```nushell
# $in needed: value used in multiple places
export def extract-timestamps []: table -> record {
    let $input = $in # a bit exagregated example, to be fixed later

    let $ts = $input | get timestamp?

    {
        first: ($ts | first)
        last: ($ts | last)
    }
}
```

### Conditional Pass-Through with Empty `{ }`

Use empty `{ }` for the branch that passes through unchanged:

```nushell
# Pass through on false condition
| if $nu.os-info.family == windows {
    str replace --all (char crlf) "\n"
} else { }

# Pass through on true condition
| if $echo { } else {
    save -f $file
}

# Multiple chained conditions
| if 'no-output' in $fence_options { return $in } else { }
| if 'separate-block' in $fence_options { generate-separate-block-fence } else { }
| if (can-append-print $in) {
    generate-inline-output-pipeline
    | generate-print-statement
} else { }
```

### `scan` for Stateful Transformations

Use `scan` from the standard library (`std/iter`) for sequences with state:

```nushell
use std/iter scan

# State machine for tracking fence context
| scan 'text' {|curr_fence prev_fence|
    match $curr_fence {
        'text' => { if $prev_fence == 'closing-fence' { 'text' } else { $prev_fence } }
        '```' => { if $prev_fence == 'text' { '```' } else { 'closing-fence' } }
        _ => { $curr_fence }
    }
}

# Use --noinit (-n) to exclude the initial value from results
| scan --noinit 'text' {|curr prev| ... }
```

### `window` for Adjacent Elements

```nushell
| window --remainder 2
| scan 0 {|window index|
    if $window.0 == $window.1? { $index } else { $index + 1 }
}
```

### Combine Consecutive `each` Closures

When consecutive `each` calls perform operations that can be piped, combine them:

```nushell
# Preferred: single each with piped operations
| each { extract-text-content | str length }

# Avoid: separate each calls
| each { extract-text-content }
| each { str length }
```

### Closure Parameters: `$in` vs Named

Use `$in` for simple single-operation closures. Use short-named parameters (`|b|`, `|r|`, `|x|`) when the closure has multiple operations or references the value more than twice:

```nushell
# Multiple operations - use named parameter
| each {|b|
    if $b.block_index in $result_indices {
        let result = $results | where block_index == $b.block_index
        $b | update line { $result.line | lines }
    }
}

# Variable used >2 times - use named parameter
| each {|r| {start: $r.start, end: $r.end, len: ($r.end - $r.start)} }

# Simple single operation - $in is fine
| each { $in + 1 }
| each { $"prefix: ($in)" }

# Field extraction - use get, not each
| get line
| get field --optional
```

### Data-First Filtering

Define all data upfront, then filter. Prefer `where` over `each {if} | compact`:

```nushell
# Preferred: data-first, filter with where
[
    [--env-config $nu.env-path]
    [--config $nu.config-path]
    [--plugin-config $nu.plugin-path]
]
| where {|i| $i.1 | path exists }
| flatten

# Avoid: spread operator with conditionals
[
    ...(if ($nu.env-path | path exists) { [--env-config $nu.env-path] } else { [] })
    ...(if ($nu.config-path | path exists) { [--config $nu.config-path] } else { [] })
]
```

### Pipeline Append vs Spread

```nushell
# Preferred: start empty, append conditionally
[]
| if $cond1 { append [a b] } else { }
| if $cond2 { append [c d] } else { }

# Or: data-first with filtering
[[a b] [c d]]
| where { some-condition $in }
| flatten
```

### Building Tables with `wrap` and `merge`

```nushell
$file_lines | wrap line
| merge ($row_type | wrap row_type)
| merge ($block_index | wrap block_index)
| group-by block_index --to-table
| insert row_type { $in.items.row_type.0 }
| update items { get line }
| rename block_index line row_type
```

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

### `match` for Type/Pattern Dispatch

```nushell
export def classify-block-action [
    $row_type: string
]: nothing -> string {
    match $row_type {
        'text' => { 'print-as-it-is' }
        '```output-numd' => { 'delete' }

        $i if ($i =~ '^```nu(shell)?(\s|$)') => {
            if $i =~ 'no-run' { 'print-as-it-is' } else { 'execute' }
        }

        _ => { 'print-as-it-is' }
    }
}
```

### `items` for Record Iteration

```nushell
$record
| items {|k v|
    $v
    | str replace -r '^\s*(\S)' '  $1'
    | str join (char nl)
    | $"($k):\n($in)"
}
```

### Safe Navigation with `?`

```nushell
$env.numd?.table-width? | default 120
$env.numd?.prepend-code?
```

### `in` for Membership Testing

```nushell
# Preferred
| where name? in ["Edit" "Write"]

# Avoid
| where { ($in.name? == "Edit") or ($in.name? == "Write") }
```

### `get --optional` for Field Extraction

Both forms produce the same result (list with nulls for missing fields), but `get` is more concise:

```nushell
# Preferred: get treats list-of-records as table
| get content --optional      # → [null, "result", null]

# Equivalent but verbose
| each { $in.content? }       # → [null, "result", null]

# For nested fields
| get input.file_path --optional

# Avoid: each + compact loses position information
| each { $in.input?.file_path? }
| compact
```

Note: `--optional` makes all path segments optional at once:
```nushell
get a.b.c --optional    # same as a?.b?.c?
get a.b?.c              # only b is optional
```

### `where` Row Conditions vs Closures

For simple conditions on lists, use row condition syntax (`$it`) instead of closures:

```nushell
# Preferred: row condition with $it
| where $it =~ $UUID_PATTERN
| where $it > 0

# Avoid: closure form for simple conditions
| where { $in =~ $UUID_PATTERN }
| where { $in > 0 }

# Closure IS needed when piping or multiple operations
| where {|i| $i.1 | path exists }
| where { $in | str starts-with "test" }
```

---

## Code Structure

### Type Signatures

Always include input/output type signatures:

```nushell
export def clean-markdown []: string -> string {
    ...
}

export def parse-markdown-to-blocks []: string -> table<block_index: int, row_type: string, line: list<string>, action: string> {
    ...
}

# Multiple return types (no commas)
export def run [
    file: path
]: [nothing -> string nothing -> nothing nothing -> record] {
    ...
}
```

### @example Attributes (nutest)

Document commands with executable examples using [nutest](https://github.com/vyadh/nutest) attributes:

```nushell
@example "generate marker for block 3" {
    code-block-marker 3
} --result "#code-block-marker-open-3"
export def code-block-marker [
    index?: int
    --end
]: nothing -> string {
    ...
}
```

### Semantic Action Labels

Use meaningful labels instead of pattern matching throughout:

```nushell
# Preferred: semantic labels
| where action == 'execute'
| where action != 'delete'

# Avoid: repeated regex matching
| where row_type =~ '^```nu(shell)?(\s|$)'
```

### Module Exports for Testing

Export all commands from implementation files. Control what's public via `mod.nu`:

```nushell
# commands.nu - export everything for testability
export def my-command [] { ... }
export def helper-function [] { ... }  # internal helper, still exported

# mod.nu - control public API
export use commands.nu [ my-command ]  # only my-command is public
```

Tests can then import everything:

```nushell
# tests/test_commands.nu
use ../module/commands.nu *  # access all exported commands including helpers
```

### Const for Static Data

```nushell
const fence_options = [
    [short long description];

    [O no-output "execute code without outputting results"]
    [N no-run "do not execute code in block"]
    [t try "execute block inside `try {}` for error handling"]
]

export def list-fence-options []: nothing -> table {
    $fence_options | select long short description
}
```

### Variable Naming

Use concise names for local variables with small scope; be more descriptive for parameters and exports:

```nushell
# Concise when scope is small and context is clear
| rename s f
| into int s f
let len = $longest_last_span_start - $last_span_end

# More descriptive for exports/parameters
export def process-blocks [block_index: int] { ... }
```

### Helper Extraction

Keep logic inline unless it's reused or the command becomes too long:

```nushell
# Inline when used once
| if (check-print-append $in) {
    create-indented-output
    | generate-print-statement
} else { }

# Extract when reused or complex
def apply-output-formatting []: string -> string { ... }
```

### Comments

Prefer comments that explain "why", not "what". **Never remove existing comments**:

```nushell
# Good: explain non-obvious decisions
# I set variables here to prevent collecting $in var
let expanded_format = "\n```\n\nOutput:\n\n```\n"
```

---

## Formatting Conventions

These follow Topiary formatter conventions.

### Empty Blocks with Space

```nushell
# Preferred
} else { }
| if $in == null { } else { str join (char nl) }

# Avoid
} else {}
```

### Closure Spacing

Single-expression closures have spaces inside braces:

```nushell
# Preferred
| update line { str join (char nl) }
| each { $in.items.row_type.0 }

# Avoid
| update line {str join (char nl)}
```

### Flag Spacing

```nushell
# Preferred
--noinit (-n)
--restore (-r)

# Avoid
--noinit(-n)
```

### Multi-line Records

```nushell
# Preferred
return {
    filename: $file
    comment: "the script didn't produce any output"
}

# Avoid
return { filename: $file,
    comment: "the script didn't produce any output" }
```

### External Command Parentheses

Avoid unnecessary parentheses around external commands:

```nushell
# Preferred
^$nu.current-exe ...$args $script
| complete

# For multi-line, use parentheses with proper formatting
(
    ^$nu.current-exe --env-config $nu.env-path --config $nu.config-path
    --plugin-config $nu.plugin-path $intermed_script_path
)
```

### Variable Declarations

No `$` prefix on left-hand side:

```nushell
# Preferred
let original_md = open -r $file

# Avoid (older style)
let $original_md = open -r $file
```

---

## Debugging with `--ide-check`

Use `nu --ide-check` for static analysis—outputs structured JSON diagnostics with precise spans.

### What It Catches

| Error Type | Detected? | Example Message |
|------------|-----------|-----------------|
| Undefined variable | ✅ | `Variable not found.` |
| Type mismatch | ✅ | `Type mismatch.` |
| Missing argument | ✅ | `Missing required positional argument.` |
| Wrong flag | ✅ | `Command doesn't have flag X` |
| Pipeline type error | ✅ | `Command does not support string input.` |
| Unclosed delimiters | ✅ | `Unclosed delimiter.` |
| Unknown command | ❌ | Runtime only (could be external) |

### Parsing Diagnostics

```nushell
def diagnose [file: path] {
    let content = open $file
    nu --ide-check 10 $file | lines | each { from json }
    | where type == "diagnostic"
    | each {|d|
        let before = $content | str substring 0..$d.span.start
        let line = ($before | split row "\n" | length)
        {
            severity: $d.severity,
            message: $d.message,
            line: $line,
            code: ($content | str substring $d.span.start..$d.span.end)
        }
    }
}
```

### Agent Workflow

1. Run `--ide-check` first (catches static errors)
2. If no errors, run the file for runtime errors
3. Parse spans to get exact line numbers and code snippets

---

## Quick Reference

### Do

- Omit `$in |` when command body starts with pipeline command (`each`, `where`, `select`)
- Start continuation lines with `|`
- Use empty `else { }` for pass-through
- Use `match` for type dispatch
- Use `in` for membership testing (not multiple `or` conditions)
- Use `get --optional` for field extraction (not `each {$in.field?} | compact`)
- Use `scan` for stateful transforms
- Use `where` for filtering (not `each {if} | compact`)
- Use `where $it =~ ...` for list filtering (not `where { $in =~ ... }`)
- Combine consecutive `each` closures when operations can be piped
- Define data first, then filter
- Include type signatures
- Use `@example` attributes (nutest)
- Use `const` for static data
- Keep custom commands focused
- Export all custom commands (`export def`), control public API via `mod.nu`
- Use `par-each --keep-order` for parallel with deterministic output
- Use `scope modules | where name == ...` for optional module checks
- Use `const` with `path join` for cross-platform module paths

### Don't

- Start command bodies with `$in |` when a pipeline command follows (redundant)
- Use spread operator `...` with conditionals (use data-first + `where`)
- Wrap external commands in unnecessary parentheses
- Over-extract helpers for one-time use
- Create wrapper commands that just call an existing command
- Add excessive documentation for internal commands
- Use verbose names for local variables
- Break the pipeline flow unnecessarily
- Remove existing comments (preserve user's context)
