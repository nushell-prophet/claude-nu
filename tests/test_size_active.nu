use std/assert
use std/testing *

# Import all functions from sessions.nu (including internals not re-exported via mod.nu)
use ../claude-nu/sessions.nu *

const FIXTURES_SESSIONS_DIR = path self fixtures/sessions

# A fake ~/.claude/projects/<proj> holding one session file per entry of
# `sessions`: {id, lines, mtime}. Returns the fake home and the project dir.
def make-store [sessions: list]: nothing -> record {
    let fake_home = $nu.temp-dir | path join $"fake-home-(random uuid)"
    let proj_dir = $fake_home | path join ".claude" "projects" "-some-encoded-dir"
    mkdir $proj_dir
    for s in $sessions {
        let file = $proj_dir | path join $"($s.id).jsonl"
        $s.lines | str join "\n" | save --force $file
        touch --modified --timestamp $s.mtime $file
    }
    {home: $fake_home dir: $proj_dir}
}

def user-line [ts: string]: nothing -> string {
    $'{"type":"user","cwd":"/real/parent/proj","message":{"content":"hi"},"timestamp":"($ts)"}'
}

# =============================================================================
# size and modified (F11)
# =============================================================================

@test
def "sessions size and modified come from the file listing" [] {
    let result = null | sessions $FIXTURES_SESSIONS_DIR --columns size,modified
    let listed = ls $FIXTURES_SESSIONS_DIR | where name ends-with ".jsonl" | select name size modified

    assert equal ($result | columns) [size modified path parent_session_id]
    for row in $result {
        let file = $listed | where name == $row.path | first
        assert equal $row.size $file.size
        assert equal $row.modified $file.modified
    }
}

@test
def "sessions size and modified are not in the default set" [] {
    let cols = null | sessions $FIXTURES_SESSIONS_DIR | columns

    assert ("size" not-in $cols)
    assert ("modified" not-in $cols)
}

@test
def "a selection of only listing columns opens no session file" [] {
    # Why: invalid JSONL fails loudly when parsed, so a row coming back at all
    # proves the file was never read.
    let store = make-store [{id: "12345678-1234-1234-1234-123456789abc" lines: ["not json"] mtime: (date now)}]

    let result = null | sessions $store.dir --columns size,modified

    rm --recursive --force $store.home

    assert equal ($result | length) 1
    assert equal $result.0.size 8b
}

@test
def "listing columns keep the requested order among parsed ones" [] {
    let result = null | sessions $FIXTURES_SESSIONS_DIR --columns modified,session_id,size

    assert equal ($result | columns) [modified session_id size path parent_session_id]
}

@test
def "a named session file carries size and modified too" [] {
    let file = $FIXTURES_SESSIONS_DIR | path join 'ef27ae6d-c8d1-4ce8-b0ff-bcfff3954193.jsonl'
    let result = null | sessions $file --columns size,modified

    assert equal $result.0.size (ls $file | get 0.size)
    assert equal $result.0.modified (ls $file | get 0.modified)
}

@test
def "subagent rows carry size" [] {
    let result = null | sessions $FIXTURES_SESSIONS_DIR --subagents --columns size | where parent_session_id != null

    assert (($result | length) > 0)
    assert ($result | all {|r| $r.size > 0b })
}

# A subagent transcript of session ...abc, and the symlink a resumed session
# ...abd holds to it, the link two days older than its target — the shape
# Claude Code writes when a session is resumed.
def linked-transcript-store []: nothing -> record {
    let store = make-store []
    let real = $store.dir | path join "12345678-1234-1234-1234-123456789abc" "subagents" "agent-a1.jsonl"
    let link = $store.dir | path join "12345678-1234-1234-1234-123456789abd" "subagents" "agent-a1.jsonl"
    mkdir ($real | path dirname) ($link | path dirname)
    user-line "2024-01-15T10:30:00Z" | save --force $real
    ^ln --symbolic $real $link
    touch --modified --no-deref --timestamp ((date now) - 2day) $link
    $store | insert real $real | insert link $link
}

@test
def "a symlinked transcript takes size and modified from its target" [] {
    let store = linked-transcript-store
    let target = ls $store.real | get 0

    let result = null | sessions $store.link --columns size,modified

    rm --recursive --force $store.home

    assert equal $result.0.path $store.link
    assert equal $result.0.size $target.size
    assert equal $result.0.modified $target.modified
}

@test
def "the mtime pre-filter reads a symlinked transcript by its target" [] {
    # Why: the link's own mtime is when the session was resumed, so a cut on it
    # would drop a transcript written long after.
    let store = linked-transcript-store

    let kept = [$store.link] | mtime-filter-session-files ((date now) - 1day)

    rm --recursive --force $store.home

    assert equal $kept [$store.link]
}

@test
def "projects size sums the top-level transcripts" [] {
    let store = make-store [
        {id: "12345678-1234-1234-1234-123456789abc" lines: [(user-line "2024-01-15T10:00:00Z")] mtime: (date now)}
        {id: "12345678-1234-1234-1234-123456789abd" lines: [(user-line "2024-01-15T10:00:00Z") (user-line "2024-01-15T11:00:00Z")] mtime: (date now)}
    ]
    # Why a subagent transcript: `size` counts the same files as `count`.
    let sub_dir = $store.dir | path join "12345678-1234-1234-1234-123456789abc" "subagents"
    mkdir $sub_dir
    user-line "2024-01-15T10:30:00Z" | save --force ($sub_dir | path join "agent-a1.jsonl")
    let expected = ls $store.dir | where name ends-with ".jsonl" | get size | math sum

    let result = with-env {HOME: $store.home} { projects }

    rm --recursive --force $store.home

    assert equal ($result | columns) [name path count size modified]
    assert equal $result.0.size $expected
}

# =============================================================================
# --active-since / --active-until (F10)
# =============================================================================

# Four sessions around a 03:00-03:30 window on 2026-08-04, all written now:
# `across` spans the window, `inside` sits in it, `before` and `after` miss it.
def window-store []: nothing -> record {
    let at = {|id first last|
        {id: $id lines: [(user-line $first) (user-line $last)] mtime: (date now)}
    }
    make-store [
        (do $at "aaaaaaaa-1234-1234-1234-123456789abc" "2026-08-04T01:00:00Z" "2026-08-04T05:00:00Z")
        (do $at "bbbbbbbb-1234-1234-1234-123456789abc" "2026-08-04T03:10:00Z" "2026-08-04T03:20:00Z")
        (do $at "cccccccc-1234-1234-1234-123456789abc" "2026-08-03T01:00:00Z" "2026-08-03T02:00:00Z")
        (do $at "dddddddd-1234-1234-1234-123456789abc" "2026-08-05T01:00:00Z" "2026-08-05T02:00:00Z")
    ]
}

@test
def "active window keeps every session whose span overlaps it" [] {
    let store = window-store
    let lo = "2026-08-04T03:00:00Z" | into datetime
    let hi = "2026-08-04T03:30:00Z" | into datetime

    let result = null | sessions $store.dir --active-since $lo --active-until $hi --columns session_id

    rm --recursive --force $store.home

    assert equal ($result | get path | each { session-id-from-path } | sort) [aaaaaaaa-1234-1234-1234-123456789abc bbbbbbbb-1234-1234-1234-123456789abc]
}

@test
def "active window alone on one side is open on the other" [] {
    let store = window-store
    let at = "2026-08-04T03:00:00Z" | into datetime

    let since = null | sessions $store.dir --active-since $at --columns path | get path | each { session-id-from-path } | sort
    let until = null | sessions $store.dir --active-until $at --columns path | get path | each { session-id-from-path } | sort

    rm --recursive --force $store.home

    assert equal $since [aaaaaaaa-1234-1234-1234-123456789abc bbbbbbbb-1234-1234-1234-123456789abc dddddddd-1234-1234-1234-123456789abc]
    assert equal $until [aaaaaaaa-1234-1234-1234-123456789abc cccccccc-1234-1234-1234-123456789abc]
}

@test
def "active window leaves the selected columns as they are" [] {
    let store = window-store

    let result = null | sessions $store.dir --active-since 2026-08-04 --columns session_id

    rm --recursive --force $store.home

    assert equal ($result | columns) [session_id path parent_session_id]
}

@test
def "active-since skips a file untouched since before it unparsed" [] {
    # Why invalid JSONL: a parse would fail loudly, so a clean empty answer
    # proves the mtime cut dropped the file first.
    let store = make-store [{id: "12345678-1234-1234-1234-123456789abc" lines: ["not json"] mtime: ((date now) - 2day)}]

    let result = null | sessions $store.dir --active-since 1day

    rm --recursive --force $store.home

    assert equal $result []
}

@test
def "a session with no timestamped record is in no active window" [] {
    let store = make-store [{id: "12345678-1234-1234-1234-123456789abc" lines: ['{"type":"summary","summary":"only a summary"}'] mtime: (date now)}]

    let result = null | sessions $store.dir --active-until 1day

    rm --recursive --force $store.home

    assert equal $result []
}

@test
def "active window and the mtime window exclude each other" [] {
    let err = try { null | sessions $FIXTURES_SESSIONS_DIR --since 1wk --active-until 1day; null } catch {|e| $e.msg }

    assert ($err | str contains "mutually exclusive")
}

@test
def "a misspelled active bound is an error naming its flag" [] {
    let err = try { null | sessions $FIXTURES_SESSIONS_DIR --active-since "nonsense"; null } catch {|e| $e.msg }

    assert ($err | str contains "--active-since")
}
