use std/assert
use std/testing *

# `main` imports under the module's name, so this yields `project-move`.
use ../claude-nu/project-move.nu *

const OLD = "/work/demo"
const NEW = "/work/moved/demo"

# One session line per record type we care about: a user turn carrying `cwd`,
# and an assistant turn whose text mentions the old path without being a pointer
# to the project. Written as literal JSON, never built with `to json`, so a test
# can compare the bytes that come back.
const USER_LINE = '{"parentUuid":null,"cwd":"/work/demo","gitBranch":"main","type":"user","message":{"role":"user","content":"café — look at /work/demo/README.md"},"version":"2.1.0","timestamp":"2026-07-01T00:00:00.000Z"}'
const ASSISTANT_LINE = '{"type":"assistant","cwd":"/work/demo","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/work/demo/README.md"}}]}}'
const SUBAGENT_LINE = '{"type":"user","cwd":"/work/demo","isSidechain":true,"message":{"role":"user","content":"go"}}'

# A home directory holding state for the project at OLD plus an unrelated
# project, so every test can check that only one of them moves.
def fake-home []: nothing -> path {
    let home = $nu.temp-dir | path join $"project-move-(random uuid)"
    let session_dir = $home | path join ".claude" "projects" "-work-demo"
    mkdir ($session_dir | path join "aaaa" "subagents")

    [$USER_LINE $ASSISTANT_LINE]
    | str join "\n"
    | $"($in)\n"
    | save --raw ($session_dir | path join "aaaa.jsonl")
    $"($SUBAGENT_LINE)\n" | save --raw ($session_dir | path join "aaaa" "subagents" "agent-1.jsonl")

    let other_dir = $home | path join ".claude" "projects" "-work-other"
    mkdir $other_dir
    '{"type":"user","cwd":"/work/other"}' | save --raw ($other_dir | path join "bbbb.jsonl")

    [
        '{"display":"hi","project":"/work/demo","sessionId":"aaaa"}'
        '{"display":"ho","project":"/work/other","sessionId":"bbbb"}'
    ]
    | str join "\n"
    | $"($in)\n"
    | save --raw ($home | path join ".claude" "history.jsonl")

    [
        '{'
        '  "projects": {'
        '    "/work/demo": {'
        '      "allowedTools": []'
        '    },'
        '    "/work/other": {}'
        '  },'
        '  "githubRepoPaths": {'
        '    "owner/demo": ['
        '      "/work/demo"'
        '    ]'
        '  }'
        '}'
    ]
    | str join "\n"
    | save --raw ($home | path join ".claude.json")
    # Claude writes both of these 0600 — they carry the account email, the
    # machine id and every prompt ever typed.
    ^chmod 600 ($home | path join ".claude.json") ($home | path join ".claude" "history.jsonl")

    $home
}

def projects-dir [home: path]: nothing -> path {
    $home | path join ".claude" "projects"
}

def mode-of [file: path]: nothing -> string {
    ls --long $file | get 0.mode
}

# =============================================================================
# What moves
# =============================================================================

@test
def "renames the sessions directory to the new encoded path" [] {
    let home = fake-home
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let old_gone = not (projects-dir $home | path join "-work-demo" | path exists)
    let new_there = projects-dir $home | path join "-work-moved-demo" | path exists
    rm -rf $home

    assert $old_gone
    assert $new_there
}

@test
def "rewrites cwd in top-level and subagent transcripts" [] {
    let home = fake-home
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let moved = projects-dir $home | path join "-work-moved-demo"
    let top = open --raw ($moved | path join "aaaa.jsonl")
    let sub = open --raw ($moved | path join "aaaa" "subagents" "agent-1.jsonl")
    rm -rf $home

    assert equal ($top | str contains '"cwd":"/work/moved/demo"') true
    assert equal ($top | str contains '"cwd":"/work/demo"') false
    assert equal ($sub | str contains '"cwd":"/work/moved/demo"') true
}

@test
def "leaves the old path where it is a record of what happened" [] {
    let home = fake-home
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let top = open --raw (projects-dir $home | path join "-work-moved-demo" "aaaa.jsonl")
    rm -rf $home

    # A file the session read and a path quoted in a message are history, not a
    # pointer to the project — rewriting them would falsify the transcript.
    assert equal ($top | str contains '"file_path":"/work/demo/README.md"') true
    assert equal ($top | str contains 'look at /work/demo/README.md') true
}

@test
def "changes nothing in a record but the cwd bytes" [] {
    let home = fake-home
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let lines = open --raw (projects-dir $home | path join "-work-moved-demo" "aaaa.jsonl") | lines
    rm -rf $home

    # The whole reason the swap is a literal substring replace: key order, the
    # é escape and every other byte survive untouched. A JSON round trip
    # would have normalized them.
    assert equal ($lines | get 0) ($USER_LINE | str replace '"cwd":"/work/demo"' '"cwd":"/work/moved/demo"')
    assert equal ($lines | get 1) ($ASSISTANT_LINE | str replace '"cwd":"/work/demo"' '"cwd":"/work/moved/demo"')
}

@test
def "moves the prompt history and the config entries" [] {
    let home = fake-home
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let history = open --raw ($home | path join ".claude" "history.jsonl")
    let config = open --raw ($home | path join ".claude.json")
    rm -rf $home

    assert equal ($history | str contains '"project":"/work/moved/demo"') true
    # Both the `projects` key and the `githubRepoPaths` value carry the path.
    assert equal ($config | str contains '"/work/moved/demo": {') true
    assert equal ($config | str contains '"/work/moved/demo"') true
    assert equal ($config | str contains '"/work/demo"') false
}

@test
def "leaves an unrelated project alone" [] {
    let home = fake-home
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let other_there = projects-dir $home | path join "-work-other" | path exists
    let history = open --raw ($home | path join ".claude" "history.jsonl")
    let config = open --raw ($home | path join ".claude.json")
    rm -rf $home

    assert $other_there
    assert equal ($history | str contains '"project":"/work/other"') true
    assert equal ($config | str contains '"/work/other"') true
}

@test
def "rewrites cwd without a rename when the encoded name is unchanged" [] {
    let home = fake-home
    # `/work/demo` and `/work-demo` both encode to `-work-demo`: the directory
    # name is lossy, so this move has nothing to rename and cwds to fix.
    with-env {HOME: $home} { project-move $OLD "/work-demo" | ignore }
    let content = open --raw (projects-dir $home | path join "-work-demo" "aaaa.jsonl")
    rm -rf $home

    assert equal ($content | str contains '"cwd":"/work-demo"') true
}

# =============================================================================
# The awkward shapes a real ~/.claude can take
# =============================================================================

@test
def "moves a project whose path holds glob metacharacters" [] {
    let home = $nu.temp-dir | path join $"project-move-(random uuid)"
    let session_dir = $home | path join ".claude" "projects" "-work-demo[1]"
    mkdir $session_dir
    '{"type":"user","cwd":"/work/demo[1]"}' | save --raw ($session_dir | path join "aaaa.jsonl")
    with-env {HOME: $home} { project-move "/work/demo[1]" $NEW | ignore }
    let content = open --raw (projects-dir $home | path join "-work-moved-demo" "aaaa.jsonl")
    rm -rf $home

    # The directory name is built from the project path, so `[1]` in it used to
    # turn the file walk into a pattern matching nothing: the sessions dropped
    # out of the plan while the rename went ahead, leaving records pointing at a
    # path that no longer exists.
    assert equal ($content | str contains '"cwd":"/work/moved/demo"') true
}

@test
def "keeps the 0600 mode of the files it rewrites" [] {
    let home = fake-home
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let config_mode = mode-of ($home | path join ".claude.json")
    let history_mode = mode-of ($home | path join ".claude" "history.jsonl")
    rm -rf $home

    assert equal $config_mode "rw-------"
    assert equal $history_mode "rw-------"
}

@test
def "rewrites through a symlinked config instead of replacing the link" [] {
    let home = fake-home
    let real = $home | path join "real-claude.json"
    mv ($home | path join ".claude.json") $real
    ^ln -s $real ($home | path join ".claude.json")
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let still_link = ls ($home | path join ".claude.json") | get 0.type
    let content = open --raw $real
    rm -rf $home

    assert equal $still_link "symlink"
    assert equal ($content | str contains '"/work/moved/demo"') true
}

@test
def "moves a project Claude knows only from its config" [] {
    let home = fake-home
    rm -rf (projects-dir $home | path join "-work-demo")
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let config = open --raw ($home | path join ".claude.json")
    rm -rf $home

    # No sessions directory to rename, so the rename must not be attempted —
    # `mv` on a missing source dies with a bare "Not found" and the plan would
    # have promised a move it could not make.
    assert equal ($report | get kind) [history config]
    assert equal ($config | str contains '"/work/moved/demo"') true
}

@test
def "refuses a file it cannot read as text" [] {
    let home = fake-home
    0x[00 ff 22 63 77 64 22] | save --raw (projects-dir $home | path join "-work-demo" "cccc.jsonl")
    let failed = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }
    let untouched = open --raw (projects-dir $home | path join "-work-demo" "aaaa.jsonl")
    rm -rf $home

    # A non-UTF8 transcript used to count as zero occurrences and vanish from
    # the plan, then throw at write time. Now it stops the move before anything
    # is written.
    assert $failed
    assert equal ($untouched | str contains '"cwd":"/work/demo"') true
}

@test
def "a run that dies partway is finished by running it again" [] {
    let home = fake-home
    let subdir = projects-dir $home | path join "-work-demo" "aaaa" "subagents"
    # A write that fails for real, in the middle of the plan: the top-level
    # transcript sorts first and gets rewritten, then this directory refuses the
    # temp file. Deterministic, unlike racing a concurrent writer.
    ^chmod 500 $subdir
    let died = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }
    let still_old_name = projects-dir $home | path join "-work-demo" | path exists

    # The rename comes last precisely so this state is recoverable: renaming
    # first would leave `src` gone and `dst` present, which is the one state the
    # collision guard refuses to touch — the move could never be finished.
    ^chmod 700 $subdir
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let moved = projects-dir $home | path join "-work-moved-demo"
    let top = open --raw ($moved | path join "aaaa.jsonl")
    let sub = open --raw ($moved | path join "aaaa" "subagents" "agent-1.jsonl")
    rm -rf $home

    assert $died
    assert $still_old_name
    # The transcript already done reports no occurrences and drops out of the
    # second plan; what is left gets written, and then the rename happens.
    assert equal ($report | get kind) [sessions-dir session history config]
    assert equal ($top | str contains '"cwd":"/work/moved/demo"') true
    assert equal ($sub | str contains '"cwd":"/work/moved/demo"') true
}

# =============================================================================
# Reporting and refusals
# =============================================================================

@test
def "refuses to rename a sessions directory two projects share" [] {
    let home = fake-home
    let shared = projects-dir $home | path join "-work-demo"
    # `/work/demo` and `/work-demo` encode to the same directory name, so this
    # transcript belongs to a different project sitting in the same folder.
    '{"type":"user","cwd":"/work-demo"}' | save --raw ($shared | path join "cccc.jsonl")
    let failed = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }
    let still_old_name = $shared | path exists
    let ours = open --raw ($shared | path join "aaaa.jsonl")
    let theirs = open --raw ($shared | path join "cccc.jsonl")
    rm -rf $home

    # The cwd rewrite only touches matching records, but `mv` takes the whole
    # directory: the co-located project's transcripts would land under the new
    # name while its own config entry still points at the old path.
    assert $failed
    assert $still_old_name
    assert equal ($ours | str contains '"cwd":"/work/demo"') true
    assert equal ($theirs | str contains '"cwd":"/work-demo"') true
}

@test
def "moves past a session file that records no cwd" [] {
    let home = fake-home
    # Claude creates the session file when a session starts and writes nothing
    # to one that dies before its first turn. A real store holds these.
    "" | save --raw (projects-dir $home | path join "-work-demo" "dead.jsonl")
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let moved = projects-dir $home | path join "-work-moved-demo" | path exists
    rm -rf $home

    # It names no project, so it strands none — counting it as a stranger's
    # transcript would refuse a move that nobody could then make.
    assert $moved
}

@test
def "finishes a rerun whose config swap already landed" [] {
    let home = fake-home
    # The state a run leaves when it dies between the config swap and the
    # rename: config and history already carry the new path, sessions do not.
    open --raw ($home | path join ".claude.json")
    | str replace --all $'"($OLD)"' $'"($NEW)"'
    | save --raw --force ($home | path join ".claude.json")
    open --raw ($home | path join ".claude" "history.jsonl")
    | str replace --all $'"project":"($OLD)"' $'"project":"($NEW)"'
    | save --raw --force ($home | path join ".claude" "history.jsonl")
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let content = open --raw (projects-dir $home | path join "-work-moved-demo" "aaaa.jsonl")
    rm -rf $home

    # The new path alone in the config is our own work, not a second project —
    # reading it as a merge would make the move impossible to finish.
    assert equal ($report | get kind) [sessions-dir session session]
    assert equal ($content | str contains '"cwd":"/work/moved/demo"') true
}

@test
def "refuses when the config already carries the destination" [] {
    let home = fake-home
    open --raw ($home | path join ".claude.json")
    | str replace '"/work/other": {}' '"/work/moved/demo": {"allowedTools": ["B"]}'
    | save --raw --force ($home | path join ".claude.json")
    let failed = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }
    let config = open --raw ($home | path join ".claude.json")
    rm -rf $home

    # The swap is textual, so rewriting the old key here would leave `projects`
    # holding "/work/moved/demo" twice — JSON a parser still reads, keeping one
    # entry and silently dropping the other project's permissions.
    assert $failed
    assert equal ($config | str contains '"/work/demo"') true
}

@test
def "dry-run reports the same rows and writes nothing" [] {
    let home = fake-home
    let plan = with-env {HOME: $home} { project-move $OLD $NEW --dry-run }
    let untouched = projects-dir $home | path join "-work-demo" | path exists
    let content = open --raw (projects-dir $home | path join "-work-demo" "aaaa.jsonl")
    rm -rf $home

    assert $untouched
    assert equal ($content | str contains '"cwd":"/work/demo"') true
    assert equal ($plan | columns) [kind path replaced]
    assert equal ($plan | get kind) [sessions-dir session session history config]
    # Two cwd occurrences in the top-level file, one in the subagent transcript,
    # one history line, and two mentions in the config.
    assert equal ($plan | get replaced) [null 2 1 1 2]
}

@test
def "reports one row per artifact touched" [] {
    let home = fake-home
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    rm -rf $home

    assert equal ($report | get kind) [sessions-dir session session history config]
    # Paths are reported where the artifact ends up, not where it was read from.
    assert equal ($report | where kind == sessions-dir | get 0.path | path basename) "-work-moved-demo"
}

@test
def "refuses a move to a path Claude already has state for" [] {
    let home = fake-home
    mkdir (projects-dir $home | path join "-work-moved-demo")
    let failed = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }
    rm -rf $home

    assert $failed
}

@test
def "refuses when no state exists for the old path" [] {
    let home = fake-home
    let failed = try { with-env {HOME: $home} { project-move "/work/nothing" $NEW }; false } catch { true }
    rm -rf $home

    assert $failed
}

@test
def "refuses a move that goes nowhere" [] {
    let home = fake-home
    # A trailing slash is the same directory; `cwd` never carries one.
    let failed = try { with-env {HOME: $home} { project-move $OLD "/work/demo/" }; false } catch { true }
    rm -rf $home

    assert $failed
}
