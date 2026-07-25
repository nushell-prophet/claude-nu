---
name: gi-canvas
description: Turn the current chat into a gi canvas, or open an existing one. Use when the user says "gi canvas", "start a canvas", "переведи в канвас", "продолжим в канвасе", "open the canvas", or asks to move this conversation into a canvas document.
argument-hint: [canvas path]
allowed-tools: Bash(nu -c *), Bash(ls *), Read
---

The user wants a canvas session but is inside a chat session, where typing nushell into Bash is awkward. Run the module command for them and hand back one line to paste into a terminal.

A canvas session cannot be started from within a session: the Canvas style, the Stop hook, and `$env.GI_CANVAS` all arrive with `claude` at launch. So this skill always ends the same way — the user runs one command themselves, in their terminal, and that new session is the canvas one.

## How to call the module

`claude-nu` is a nushell module command, not a program on PATH: it is loaded in the user's interactive REPL, and a one-shot `nu -c` does not load it. So every command **you** run has to import it first:

```nushell
nu -c 'use ~/repos/claude-nu/claude-nu/; claude-nu gi'
```

If that path does not exist on this machine, find the module (`ls ~/repos/claude-nu ~/git/claude-nu`) and use the real one.

The commands **the user** runs go into their REPL, where the module is already loaded — hand those over bare: `claude-nu gi open <doc>`.

## Which case

Read `$ARGUMENTS` and the conversation:

- **No canvas yet, and this chat is worth keeping** (the usual case) → import this session.
- **No canvas yet, nothing here worth keeping** → a blank canvas.
- **A canvas path is given or exists in `gi/`** → open it.

A canvas keeps one session for life, and `gi open` handles both halves of that: a canvas with no `session:` in its frontmatter gets one minted and written in, one that has it is resumed. You do not have to tell them apart.

`gi` on its own tells you what is seeded here and whether this session is already bound (`canvas` non-null → it already is a canvas session; say so and stop). `ls gi/*.md` lists the repo's canvases.

## Import this session

```nushell
nu -c 'use ~/repos/claude-nu/claude-nu/; claude-nu gi enable --from-session'          # → gi/session-<id>.md, seeds style + skills
nu -c 'use ~/repos/claude-nu/claude-nu/; claude-nu gi enable --from-session --tools'  # ...keeping tool calls as one-line placeholders
nu -c 'use ~/repos/claude-nu/claude-nu/; claude-nu gi enable notes/x.md --from-session' # ...at a chosen path
```

It refuses to overwrite an existing doc — that is deliberate, do not delete the old one to get past it; name another path instead (`gi enable <doc> --from-session`).

Then tell the user, in one line: exit this session and run `claude-nu gi open <doc>`. The import wrote this session's id into the canvas, so that reopens **this same session** (same id, full context) with the canvas bound, and the missing tail — the turns after the import, which the session log cannot contain yet — is still in context and can be appended there.

## Blank canvas, or an existing one

`gi open` launches Claude Code itself, so the user runs it — not you. Hand over one of these, as is:

```nushell
claude-nu gi open                 # new timestamped canvas, then launch
claude-nu gi open gi/plan.md      # a named one; created if new, resumed if it holds a session
claude-nu gi open <doc> --no-hook # style only, no Stop-hook floor
```

## What to report

One line with the exact command to run. No explanation of the protocol, no summary of what the canvas is; the style file does that once the session starts.
