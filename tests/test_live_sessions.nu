use std/assert
use std/testing *

# The module entry point, so `claude-nu live-sessions` is callable as users call it.
use ../claude-nu

# Tests for `live-sessions`: which registry files count as running sessions.
# The live entry is this test's own nu process.

# The start time of a process as Linux /proc records it; empty on macOS, where
# `live-sessions` checks the pid alone.
def proc-start [pid: int]: nothing -> string {
    if not ('/proc' | path exists) { return '' }
    open --raw $'/proc/($pid)/stat' | str replace --regex '.*\) ' '' | split row ' ' | get 19
}

# A fake HOME whose ~/.claude/sessions holds a live entry (this nu process), a
# dead one (a pid no process has), and a half-written file.
def registry-home []: nothing -> path {
    let home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let registry = $home | path join '.claude' 'sessions'

    mkdir $registry
    {pid: $nu.pid sessionId: 'live-id' cwd: '/work/live' procStart: (proc-start $nu.pid) startedAt: 1792556304858 status: busy name: live}
    | to json | save ($registry | path join 'live.json')
    # Why this pid: above the Linux pid_max limit, so no process can have it.
    {pid: 4194305 sessionId: 'dead-id' cwd: '/work/dead' procStart: '1' startedAt: 1792556304858}
    | to json | save ($registry | path join 'dead.json')
    '{"pid": 1, "sessionId": "half' | save ($registry | path join 'half.json')
    $home
}

@test
def "live-sessions keeps only the entry whose process runs" [] {
    let home = registry-home
    let result = with-env {HOME: $home} { claude-nu live-sessions }

    rm --recursive $home

    assert equal ($result | select session cwd status project project_name) [
        {session: 'live-id' cwd: '/work/live' status: busy project: '-work-live' project_name: 'work/live'}
    ]
    assert equal $result.0.started 2026-10-21T04:18:24.858+00:00
}

@test
def "a reused pid with another start time does not count" [] {
    # Why the return: macOS has no /proc and no start time to compare.
    if not ('/proc' | path exists) { return }
    let home = registry-home
    let registry = $home | path join '.claude' 'sessions'

    {pid: $nu.pid sessionId: 'reused-id' cwd: '/work/reused' procStart: '1'}
    | to json | save ($registry | path join 'reused.json')
    let result = with-env {HOME: $home} { claude-nu live-sessions }

    rm --recursive $home

    assert equal ($result | get session) ['live-id']
}

@test
def "live-sessions is empty without a registry" [] {
    let home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let result = with-env {HOME: $home} { claude-nu live-sessions }

    assert equal $result []
}
