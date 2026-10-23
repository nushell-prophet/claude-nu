# claude-nu live-sessions: the Claude Code sessions running on this machine,
# read from the registry Claude Code keeps in ~/.claude/sessions.

use discovery.nu [encode-project-dir project-display-name]

# The Claude Code sessions running on this machine, one row per process:
# {session, name, status, cwd, pid, kind, started, updated, project, project_name}.
# Read from ~/.claude/sessions/<pid>.json, a registry Claude Code writes itself;
# its format is undocumented and follows the Claude Code version.
# `cwd` is where the session started, not where it works now.
# `session` and `project` make a row a selector, so it pipes on into `messages`
# and the rest — but a session that has not written a transcript yet fails there.
# Why every session, not the current project's: the registry is machine-wide, and
# the question it answers is "what runs where"; `where cwd == (pwd)` narrows it.
@category claude-nu
@example "sessions started in this directory" { claude-nu live-sessions | where cwd == (pwd) }
@example "the sessions working right now" { claude-nu live-sessions | where status == busy | select name cwd }
@example "what the sessions started here were asked" { claude-nu live-sessions | where cwd == (pwd) | claude-nu messages }
export def main []: nothing -> table {
    # Why one `ps`: on macOS it lists every process, so it runs once, not per entry.
    let alive = if ('/proc' | path exists) { {|| proc-alive } } else {
        let pids = ps | get pid

        {|| $in.pid in $pids }
    }

    $env.HOME
    | path join '.claude' 'sessions' '*.json'
    | glob $in
    # Why try: Claude Code rewrites a file on every status change, and a
    # half-written one must not fail the whole table.
    | each {|f| try { open $f } catch { null } }
    | compact
    | where $alive
    | each {|s|
        {
            session: $s.sessionId
            name: $s.name?
            status: $s.status?
            cwd: $s.cwd
            pid: $s.pid
            kind: $s.kind?
            started: ($s.startedAt? | if $in == null { } else { $in * 1_000_000 | into datetime })
            updated: ($s.updatedAt? | if $in == null { } else { $in * 1_000_000 | into datetime })
            project: ($s.cwd | encode-project-dir)
            project_name: ($s.cwd | project-display-name)
        }
    }
    | sort-by started
}

# Whether the process a registry entry names still runs, by Linux /proc.
# Why the start time: a file outlives a crashed session, and the kernel reuses
# its pid. Why the state: PID 1 of the container does not reap, so a dead
# session stays a zombie with its old start time. The same check as the mono's
# .claude/hooks/worktree-guard.sh. macOS has no /proc: there `main` checks the
# pid alone.
export def proc-alive []: record -> bool {
    let s = $in

    try { open --raw $'/proc/($s.pid)/stat' } catch { '' }
    | str replace --regex '.*\) ' ''
    | split row ' '
    | $in.0? != null and $in.0 != 'Z' and $in.19? == $s.procStart?
}
