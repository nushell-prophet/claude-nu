---
name: run-claude-nu
description: Run, drive and re-verify claude-nu against the newest Claude Code sessions on disk. Use when asked to run, start, smoke-test, screenshot or check claude-nu, after upgrading Claude Code, or when a sessions column, a message count, or an export looks empty or wrong.
---

# Run and re-verify claude-nu

claude-nu reads Claude Code's transcript files.
Claude Code ships several times a week and changes that format without telling anyone.
So the module's readers go stale quietly: a renamed field leaves a column empty, a new content block renders as an empty string, a new wrapper around a user message gets counted as something a human typed.
Nothing throws an error.

The unit tests cannot catch this, because they run on fixtures frozen at the version they were written for.
Measured on 2026-08-17: on a clean run `nu toolkit.nu test` reported **243 passed, 0 failed**, while the drift check below found four real problems in the same tree.
Two of them were readers that had stopped reading anything at all.

The driver is `.claude/skills/run-claude-nu/drift.nu`.
It checks the module against the newest sessions on your disk instead of against fixtures.
All paths below are relative to the repo root.

**Backward compatibility is not a goal.**
claude-nu reads the transcripts of the Claude Code you are running, not of the ones you used to run.
When the driver reports a reader as `dead`, delete the reader — do not keep both paths.

## Prerequisites

Nushell, and a populated `~/.claude/projects`.
Nothing to install: the driver imports the module by path, so it does not need the autoload that normally provides `claude-nu` in the REPL.
The `claude` CLI is used only to print the version in the header, and a missing one degrades to `unknown`.

## Run (agent path)

```bash
nu .claude/skills/run-claude-nu/drift.nu
```

7.5 seconds over the newest 40 session files. Flags:

```bash
nu .claude/skills/run-claude-nu/drift.nu --window 80    # read more sessions
nu .claude/skills/run-claude-nu/drift.nu --json         # real JSON on stdout
nu .claude/skills/run-claude-nu/drift.nu --fail         # exit 1 when anything needs attention
```

The report has four parts.

**drift** — record types, content blocks, tool names, usage fields and user-message wrapper tags found in the window, compared against `known.nuon`. Three verdicts:

| verdict | meaning | what you do |
|---|---|---|
| `new` | the sessions hold a shape the baseline never saw | look at a sample, then add an entry to `known.nuon` |
| `dead` | the baseline says a reader handles this, and no recent session produces it | delete that reader and its baseline entry |
| `todo` | already triaged and understood, not yet fixed | fix it, or leave it — it keeps being reported |

**tag classification** — asks `is-user-text` whether each wrapper tag is dropped, and compares that with the `drops` field in `known.nuon`.
They disagree when someone edits one without the other, which is how an injected block starts counting as a human turn.

**columns blank in every session** — runs `sessions --all-columns` over the same window and reports each column's blank rate.
A column blank in every recent session is a reader that has stopped reading.
Columns that are legitimately blank are listed in `known.nuon` under `expected_blank_columns` and excluded.

**smoke** — every read-only public command, run for real: `projects`, `sessions --all-columns`, `sessions | messages`, `messages --include-responses`, `export-session`, `commits --by-month`, `code-authorship`, `gi`.
Writing verbs are deliberately absent: `gi open` launches `claude`, and `gi enable` / `gi import` / `project-move` change the tree.

The very first run, on 2026-08-17 against Claude Code 2.1.233, is the best worked example — it hit every verdict at once:

```
── drift ──
record_types  attachment       1258  todo
record_types  custom-title       31  todo
tool_names    Task                0  dead
user_tags     system-reminder     1  todo

── columns blank in every session of the window ──
thinking_level   40/40
slug             40/40

── smoke ──
all 8 commands ran
```

All six were resolved in the commits right after that run: `Task` and `slug` deleted, `thinking_level` repointed at `effort`, `<system-reminder>` added to the prefix filter, `custom-title` given precedence in `extract-summary`, and `attachment` argued down to `ignored` in `known.nuon`.
A clean run since then reports `none` in every section.

## After a Claude Code upgrade

This is the routine the skill exists for.

1. Use the new version for a day, so the window holds sessions it wrote. The header prints the versions it found, so you can tell.
2. `nu .claude/skills/run-claude-nu/drift.nu`
3. Fix or triage every row. A `dead` row means delete code, not guard it.
4. Update `known.nuon` in the same commit as the fix. The baseline is the record of what claude-nu believes about the format, so it must move when the belief moves.
5. `nu toolkit.nu test` — the fixtures still have to pass.

## The baseline

`known.nuon` holds one entry per format fact, each with a `status` and a `note` saying why.
Statuses: `handled` (a reader consumes it), `ignored` (deliberately not read), `rare` (real but too infrequent for a 40-session window, so exempt from the `dead` check), `todo` (seen, understood, unfixed).
Wrapper tags carry an extra `drops` field: `true` when `SYSTEM_PREFIXES` should swallow the tag because nobody typed it.

Keep the notes specific.
A note that says "internal" tells the next agent nothing; a note that says which subtypes carry user content saves it a re-investigation.

## Run (human path)

In the REPL the module is autoloaded, so the commands are just there:

```nushell
claude-nu sessions --last --all-columns
```

That is the surface the driver smoke-tests. There is no server and no GUI.

## Test

```bash
nu toolkit.nu test              # 243 tests, JSON when piped, human view on a terminal
nu toolkit.nu check             # static syntax check of every tracked .nu file
```

`nu toolkit.nu test` is flaky, and it is not you.
Across six full runs on 2026-08-17 it reported between 0 and 2 failures, always in `tests/test_gi.nu`, and never the same test twice: `the commit flag puts the import into git history`, `an imported canvas carries the full session id in its frontmatter`, `status reports seeds differing from the module as stale`.
Those tests share a temp root, so they look order- or concurrency-dependent.
Re-run before you believe a failure, and compare the failing name against that list.

The driver itself is checked the same way as the rest of the repo:

```bash
nu --config ~/.config/nushell/autoload/modules-core.nu --commands 'dotnu diagnose .claude/skills/run-claude-nu/drift.nu'
```

## Gotchas

- **The window is mtime-ordered across every project, not just this one.** Sessions you are running right now are in it — including the one reading this. That is on purpose: the newest format shows up there first.
- **A small window invents blank columns.** At `--window 5` three columns read as blank in every session; at `--window 40` only the two real ones do. Do not triage a blank column from a small run.
- **MCP tool names are collapsed to one `mcp__*` entry.** They are `mcp__<server>__<tool>` and depend on which servers the user connected, so listing them one by one produced a fresh batch of `new` rows at `--window 80` that would never settle.
- **`where a != b` compares the column to the literal string `"b"`.** This bit the driver's own tag check, which then reported all 12 tags as mismatched instead of none. Inside `where`, a bare word on the right is a string. Use a closure: `where {|r| $r.a != $r.b }`.
- **`get attachment | flatten` fails** with "can only flatten one inner list at a time" once more than one column holds a list. Use `each {|a| ... }` to reach inside a per-record list.
- **`--json` had to serialize.** Returning the record from `main` renders it as a display table with `{record 4 fields}` placeholders — unparseable. The driver calls `to json` itself.
- **The driver reads raw records, not the module's extractors,** for everything except wrapper tags. The module is what is under test, so it must not also be the instrument. Tags are the exception because a tag only matters if it survives into what `messages` returns, and the renderer is what decides that.
- **`rare` is not a synonym for `ignored`.** Both skip the `dead` check, but `rare` says the reader is live and the window is just too small. Marking a live reader `ignored` hides it forever.

## Troubleshooting

**`No session files under /home/agent/.claude/projects`** — the container has no session history yet. Run `claude` once, or point `$env.HOME` at a home that has one.

**A `dead` row for something you know is real** — the window was too small, or it only appears in a session type you have not run lately. Widen the window before deleting anything; if it shows up, change the entry to `rare` with a note saying when it appears.

**The run is slow** — cost grows with the window, since every file in it is fully decoded. Measured: 40 files in 7.5 s, 80 files in 11.1 s.
