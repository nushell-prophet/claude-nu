use std/assert
use std/testing *

# Import all functions from sessions.nu (including internals not re-exported via mod.nu)
use ../claude-nu/sessions.nu *

# A session file built from the given JSONL lines, in the temp dir.
def session-file [lines: list<string>]: nothing -> path {
    let f = $nu.temp-dir | path join $"test-context-kind-(random uuid).jsonl"
    $lines | str join "\n" | save --force $f
    $f
}

# =============================================================================
# kind
# =============================================================================

# Record shapes as Claude Code writes them: a `!git log` is two user records,
# the input and its output; a meta turn and a caveat wrapper are written by
# Claude Code itself.
const KIND_LINES = [
    '{"type":"user","uuid":"u1","message":{"content":"fix the parser"},"timestamp":"2024-01-15T10:00:00Z"}'
    '{"type":"user","uuid":"u2","message":{"content":"<bash-input>git log</bash-input>"},"timestamp":"2024-01-15T10:00:01Z"}'
    '{"type":"user","uuid":"u3","message":{"content":"<bash-stdout>commit abc</bash-stdout><bash-stderr></bash-stderr>"},"timestamp":"2024-01-15T10:00:02Z"}'
    '{"type":"user","uuid":"u4","isMeta":true,"message":{"content":[{"type":"text","text":"Base directory for this skill"}]},"timestamp":"2024-01-15T10:00:03Z"}'
    '{"type":"user","uuid":"u5","message":{"content":"<local-command-caveat>Caveat: generated</local-command-caveat>"},"timestamp":"2024-01-15T10:00:04Z"}'
    '{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"done"}]},"timestamp":"2024-01-15T10:00:05Z"}'
    '{"type":"user","uuid":"u6","message":{"content":"<selected-text file=\"x.nu\">def a [] {}</selected-text>\n\nwhy this?"},"timestamp":"2024-01-15T10:00:06Z"}'
]

@test
def "messages names the kind of each user row" [] {
    let f = session-file $KIND_LINES
    let result = {path: $f} | messages | select uuid kind
    rm $f

    assert equal $result [
        [uuid kind];
        [u1 typed]
        [u2 bash-input]
        [u3 bash-output]
        [u6 typed]
    ]
}

@test
def "messages marks meta and wrapper rows as system" [] {
    let f = session-file $KIND_LINES
    let result = {path: $f} | messages --include-system | where kind == system | get uuid
    rm $f

    assert equal $result [u4 u5]
}

# Records Claude Code writes on its own under `type: "user"`, as real sessions
# hold them: ToolSearch's result with its "Tool loaded." text beside it, and the
# summary a compaction opens the continued session with. u3 is the user's own
# words, sent while a tool ran, riding on that tool's result — it stays typed.
const AUTHORLESS_LINES = [
    '{"type":"user","uuid":"u1","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"tool_reference","tool_name":"Read"}]},{"type":"text","text":"Tool loaded."}]},"timestamp":"2024-01-15T10:00:00Z"}'
    '{"type":"user","uuid":"u2","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"content":"This session is being continued from a previous conversation that ran out of context."},"timestamp":"2024-01-15T10:00:01Z"}'
    '{"type":"user","uuid":"u3","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"File created"},{"type":"text","text":"and also check the git log"}]},"timestamp":"2024-01-15T10:00:02Z"}'
]

@test
def "messages marks a Tool loaded record and a compact summary as system" [] {
    let f = session-file $AUTHORLESS_LINES
    let all = {path: $f} | messages --include-system | select uuid kind
    let typed = {path: $f} | messages | get uuid
    rm $f

    assert equal $all [[uuid kind]; [u1 system] [u2 system] [u3 typed]]
    assert equal $typed [u3]
}

@test
def "messages marks assistant rows as response" [] {
    let f = session-file $KIND_LINES
    let result = {path: $f} | messages --include-responses | where role == assistant | get kind
    rm $f

    assert equal $result [response]
}

@test
def "messages kind is read from the record, not from the rendered text" [] {
    # Why: the typed message below renders to the same fenced block that a
    # `<bash-input>` record renders to — only the record tells them apart.
    let f = session-file [
        '{"type":"user","uuid":"u1","message":{"content":"```sh\ngit log\n```"},"timestamp":"2024-01-15T10:00:00Z"}'
        '{"type":"user","uuid":"u2","message":{"content":"<bash-input>git log</bash-input>"},"timestamp":"2024-01-15T10:00:01Z"}'
    ]
    let result = {path: $f} | messages
    rm $f

    assert equal ($result.message | uniq | length) 1 "both render the same"
    assert equal $result.kind [typed bash-input]
}

@test
def "messages --raw rows carry the kind too" [] {
    let f = session-file $KIND_LINES
    let result = {path: $f} | messages --raw | get kind
    rm $f

    assert equal $result [typed bash-input bash-output typed]
}

@test
def "message-kind reads a bash-stderr-only output as bash-output" [] {
    let record = {type: user message: {content: "<bash-stderr>fatal: no repo</bash-stderr>"}}

    assert equal ($record | message-kind) bash-output
}

# =============================================================================
# --context
# =============================================================================

# Six typed messages m1..m6, one second apart; `needle` sits in m2 and m4.
const CONTEXT_LINES = [
    '{"type":"user","uuid":"m1","message":{"content":"one"},"timestamp":"2024-01-15T10:00:01Z"}'
    '{"type":"user","uuid":"m2","message":{"content":"two needle"},"timestamp":"2024-01-15T10:00:02Z"}'
    '{"type":"user","uuid":"m3","message":{"content":"three"},"timestamp":"2024-01-15T10:00:03Z"}'
    '{"type":"user","uuid":"m4","message":{"content":"four needle"},"timestamp":"2024-01-15T10:00:04Z"}'
    '{"type":"user","uuid":"m5","message":{"content":"five"},"timestamp":"2024-01-15T10:00:05Z"}'
    '{"type":"user","uuid":"m6","message":{"content":"six"},"timestamp":"2024-01-15T10:00:06Z"}'
]

@test
def "messages --context returns the rows around each hit, each once" [] {
    let f = session-file $CONTEXT_LINES
    let result = {path: $f} | messages needle --context 1 | select uuid hit
    rm $f

    # m3 neighbours both hits and comes back once.
    assert equal $result [
        [uuid hit];
        [m1 false]
        [m2 true]
        [m3 false]
        [m4 true]
        [m5 false]
    ]
}

@test
def "messages --context 0 returns the hits alone" [] {
    let f = session-file $CONTEXT_LINES
    let result = {path: $f} | messages needle --context 0 | select uuid hit
    rm $f

    assert equal $result [[uuid hit]; [m2 true] [m4 true]]
}

@test
def "messages --context stays inside the session of the hit" [] {
    let hit_file = session-file [
        '{"type":"user","uuid":"h1","message":{"content":"needle"},"timestamp":"2024-01-15T10:00:01Z"}'
    ]
    let other_file = session-file [
        '{"type":"user","uuid":"o1","message":{"content":"nearby in time"},"timestamp":"2024-01-15T10:00:02Z"}'
    ]
    let result = [$hit_file $other_file] | messages needle --context 3 | get uuid
    rm $hit_file $other_file

    assert equal $result [h1]
}

@test
def "messages --context leaves no neighbour of a hit dropped as a copy" [] {
    # Why: a resumed session copies its parent's records under the same uuid,
    # and the copy of the hit is dropped from it, so the row after the copy
    # point must not stay behind as context for a hit that session no longer
    # returns.
    let parent = session-file [
        '{"type":"user","uuid":"p1","message":{"content":"one"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","uuid":"p2","message":{"content":"two needle"},"timestamp":"2024-01-15T10:00:02Z"}'
    ]
    let resumed = session-file [
        '{"type":"user","uuid":"p1","message":{"content":"one"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"user","uuid":"p2","message":{"content":"two needle"},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"user","uuid":"r1","message":{"content":"after the resume"},"timestamp":"2024-01-15T10:00:03Z"}'
    ]
    let result = [$resumed $parent] | messages needle --context 1 | select uuid hit session
    rm $parent $resumed

    let parent_id = $parent | session-id-from-path
    assert equal $result [[uuid hit session]; [p1 false $parent_id] [p2 true $parent_id]]
}

@test
def "messages --context takes its neighbours from the dialogue the flags select" [] {
    # Why: with --include-responses the reply before a prompt is its neighbour;
    # without it the neighbour is the previous user row.
    let f = session-file [
        '{"type":"user","uuid":"u1","message":{"content":"first"},"timestamp":"2024-01-15T10:00:01Z"}'
        '{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"a reply"}]},"timestamp":"2024-01-15T10:00:02Z"}'
        '{"type":"user","uuid":"u2","message":{"content":"needle"},"timestamp":"2024-01-15T10:00:03Z"}'
    ]
    let with_responses = {path: $f} | messages needle --context 1 --include-responses | get uuid
    let typed_only = {path: $f} | messages needle --context 1 | get uuid
    rm $f

    assert equal $with_responses [a1 u2]
    assert equal $typed_only [u1 u2]
}

@test
def "messages --context rows are cut by the time window" [] {
    let f = session-file $CONTEXT_LINES
    let result = {path: $f} | messages needle --context 1 --since 2024-01-15T10:00:03Z | get uuid
    rm $f

    # m2 is outside the window, so neither it nor its context before m3 returns.
    assert equal $result [m3 m4 m5]
}

@test
def "messages without --context has no hit column" [] {
    let f = session-file $CONTEXT_LINES
    let result = {path: $f} | messages needle
    rm $f

    assert ("hit" not-in ($result | columns))
}

@test
def "messages --raw --context marks the hit on raw rows" [] {
    let f = session-file $CONTEXT_LINES
    let result = {path: $f} | messages needle --context 1 --raw | where hit | get uuid
    rm $f

    assert equal $result [m2 m4]
}

@test
def "messages --context without a regex is an error" [] {
    let f = session-file $CONTEXT_LINES
    let result = try { {path: $f} | messages --context 2; "no error" } catch {|e| $e.msg }
    rm $f

    assert equal $result "--context needs a regex"
}

@test
def "messages --context refuses a negative count" [] {
    let f = session-file $CONTEXT_LINES
    let result = try { {path: $f} | messages needle --context -1; "no error" } catch {|e| $e.msg }
    rm $f

    assert equal $result "--context cannot be negative"
}
