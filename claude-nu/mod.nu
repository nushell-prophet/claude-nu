# claude-nu - Nushell utilities for Claude Code
#
# Public commands (see README.md for details):
#   projects        # List Claude Code projects, most recent first
#   sessions        # Parse sessions into a structured table
#   messages        # Extract user messages from a session
#   tool-calls      # Extract the tool calls of a session — what the agent did
#   slash-commands  # Extract the slash commands invoked in a session — what you typed
#   export-session  # Render a session's dialogue to markdown
#   project-move    # Retarget Claude's stored state from a project's old path to its new one
#   gi              # gi protocol: status on its own; gi enable seeds a repo, gi import turns a session into a canvas, gi open launches a session bound to one
#   example         # Pick a pipeline from the module's own `@example` blocks and paste it into your command line
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
    projects messages tool-calls slash-commands main export-session
]
# `gi check` is deliberately absent: it is the Stop hook's body, not a verb a
# user types, and the hook imports it straight from gi.nu (see GI_COMMAND).
export use gi.nu [ main "gi enable" "gi import" "gi open" ]
# `main` imports under the module's own name — this is `claude-nu project-move`.
export use project-move.nu [ main ]
export use example.nu [ main ]

# Why the module keeps a `main` at all: without one the bare name `claude-nu`
# falls through to an external-command lookup and answers "command not found" —
# one line after `claude-nu sessions` worked, which reads as "the module isn't
# installed". It is a signpost and nothing else: it takes no search term, because
# scope now lives left of the pipe (see the note above), so all it can do is name
# the subcommands and point at the examples.
#
# The pipelines it used to spell out by hand now hang here as `@example` blocks:
# a pipeline crosses commands, so no single subcommand owns it, and the module's
# own `main` is the one place that covers all of them. They reach `help
# claude-nu`, `claude-nu example` and `dotnu examples-update` from this one copy.
@category claude-nu
@example "search this project's messages" { claude-nu messages 'regex' }
@example "search every project" { claude-nu sessions --all-projects | claude-nu messages 'regex' }
@example "full dialogues of the sessions that match" { claude-nu sessions | claude-nu messages 'regex' | claude-nu messages --include-responses }
@example "markdown of the most recent session" { claude-nu sessions --last | claude-nu export-session }
@example "the slash commands I use most, across every project" { claude-nu sessions --all-projects | claude-nu slash-commands | histogram command }
@example "what an agent ran, across every project" { claude-nu sessions --all-projects | claude-nu tool-calls 'claude-nu (sessions|messages)' }
@example "which project was that in" { claude-nu sessions --all-projects | claude-nu messages 'regex' | get project_name | uniq --count | sort-by count --reverse }
@example "search one project, picked by name" { claude-nu projects | where name =~ 'cozy' | claude-nu sessions | claude-nu messages 'vendor' }
@example "where Claude explained it, not where I asked" { claude-nu sessions --all-projects | claude-nu messages 'regex' --include-responses | where role == assistant }
@example "archive the current session next to the code" { claude-nu sessions --last | claude-nu export-session | save docs/sessions/topic.md }
@example "one session found by fuzzy match, then its markdown" { claude-nu sessions | find 'canvas' | first | claude-nu export-session }
export def main []: nothing -> any {
    error make --unspanned {
        msg: "claude-nu needs a subcommand"
        help: ([
            "subcommands: projects, sessions, messages, tool-calls, slash-commands, export-session, project-move, gi, example"
            "pipelines to try: claude-nu example <tab>"
        ] | str join "\n")
    }
}
