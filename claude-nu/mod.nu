# claude-nu - Nushell utilities for Claude Code
#
# Public commands (see README.md for details):
#   projects        # List Claude Code projects, most recent first
#   sessions        # Parse sessions into a structured table
#   messages        # Extract user messages from a session
#   export-session  # Render a session's dialogue to markdown; --to writes it to files
#   project-move    # Retarget Claude's stored state from a project's old path to its new one
#   commits         # Per-commit Claude-authorship table; --by-month for the monthly share
#   code-authorship # Claude's share of the lines living in the tree now (git blame)
#   gi              # gi protocol: status on its own; gi enable seeds a repo, gi import turns a session into a canvas, gi open launches a session bound to one
#
# Usage:
#   use claude-nu
#   claude-nu messages 'regex'                     # search this project's messages
#   claude-nu sessions --all-projects | claude-nu messages 'regex'

# Why no umbrella search (the old `claude-nu -f 'regex'`): search was written
# three ways that differed only in scope, and scope was the one thing the syntax
# didn't show. Now it is always to the left of the pipe — `messages 'x'` for this
# project, `sessions --all-projects | messages 'x'` for every project — and the
# rg pre-filter that made `-f` fast moved into `messages`, where the scope is.
export use sessions.nu [
    projects messages main export-session
]
# `gi check` is deliberately absent: it is the Stop hook's body, not a verb a
# user types, and the hook imports it straight from gi.nu (see GI_COMMAND).
export use gi.nu [ main "gi enable" "gi import" "gi open" ]
# `main` imports under the module's own name — this is `claude-nu project-move`.
export use project-move.nu [ main ]
export use attribution.nu [ commits code-authorship ]

# Why the module keeps a `main` at all: without one the bare name `claude-nu`
# falls through to an external-command lookup and answers "command not found" —
# one line after `claude-nu sessions` worked, which reads as "the module isn't
# installed". It is a signpost and nothing else: it takes no search term, because
# scope now lives left of the pipe (see the note above), so all it can do is name
# the subcommands and the two search shapes.
export def main []: nothing -> any {
    error make --unspanned {
        msg: "claude-nu needs a subcommand"
        help: ([
            "search this project:  claude-nu messages 'regex'"
            "search every project: claude-nu sessions --all-projects | claude-nu messages 'regex'"
            "subcommands: projects, sessions, messages, export-session, project-move, commits, code-authorship, gi"
        ] | str join "\n")
    }
}
