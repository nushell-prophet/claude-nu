---
status: draft
created: 20260510-2001
updated: 20260510-2001
---

# Initial request (only the user can edit this section)

Audit on 2026-05-10 against nushell 0.112.2 found a stale flag, a
multi-word subcommand bug, and a few missing flags in
`completions/nu.nu`. Fix.

# LLM agent updates section

## Findings

The dynamic AST-based subcommand discovery still works — `ast --flatten`
output shape (`content`/`shape`/`span`) is unchanged in 0.112.2, and
`parse-script-commands` correctly extracts subcommand names and `--flag`
names from real scripts including `def "main foo"`,
`export def "main exported-cmd"`, `def --env`, and `def --wrapped`.

### BROKEN

1. **`--threads` flag is removed in 0.112.2.**
   Verified: `nu --threads 4 -c 'print x'` errors with
   `Unknown flag '--threads'`. The completer still suggests it
   (`completions/nu.nu:69`).

2. **Multi-word subcommand flags don't complete.**
   `parse-script-commands` correctly returns `name: "bar baz"`, but
   `nu-complete nu subcommands` (lines 38–52) splits the typed context by
   whitespace into `["bar", "baz"]` and checks each individually against
   `subcmd_names`. Neither token matches the joined `"bar baz"`, so
   `matches` is empty and the completer falls back to suggesting subcommand
   names instead of that subcommand's `--flags`. Reproducer: a script with
   `def "main bar baz" [...]` plus typing `nu script.nu bar baz <TAB>`.
   Fix direction: longest-prefix match against `subcmd_names`, or join
   `typed_args` and check `starts-with`.

### MISSING from `extern main` flag list (0.112.2 `nu --help`)

- `--mcp-transport: string` (stdio | http)
- `--mcp-port: int` (default 8080)
- `--log-file: path` (used with `--log-target file`)

### NOTE (cosmetic, not blocking)

- Type narrowing opportunities: `--log-include` / `--log-exclude` /
  `--experimental-options` are variadic in real `nu --help` but declared
  scalar; `--config` / `--env-config` / `--plugin-config` are `path` not
  `string`; `--plugins` is `path...`. Functional, just less precise hints.
- Short flags (`-x`) defined inside script signatures aren't extracted —
  the regex `--(\w[\w-]*)` requires `--`. By design, but worth flagging.

## Implementation plan

- [ ] Remove `--threads` from the `extern main` block.
- [ ] Add `--mcp-transport`, `--mcp-port`, `--log-file`.
- [ ] Fix multi-word subcommand matching in `nu-complete nu subcommands`.
- [ ] (Optional) Tighten variadic and path types.
- [ ] Add tests: write a tiny fixture script with a multi-word subcommand
      and assert flag completion works; add a smoke test that the static
      flag list matches `nu --help` (or at least doesn't reference removed
      flags).

## Affected files

- `completions/nu.nu` (lines 38–52, 55–89)
- `tests/test_commands.nu` or new `tests/test_completions.nu`
