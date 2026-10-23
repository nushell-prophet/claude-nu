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

# A store already standing at the new encoded path, holding one file. This is
# what a project that has moved before comes back to.
def seed-destination [home: path rel: string content: string]: nothing -> path {
    let dst = projects-dir $home | path join "-work-moved-demo"
    let file = $dst | path join $rel

    mkdir ($file | path dirname)
    $content | save --raw $file
    $dst
}

# A source transcript as it looks once its cwd has been swapped — what the fold
# compares against, since the swap runs first.
def rewritten [...lines: string]: nothing -> string {
    $lines
    | str join "\n"
    | $"($in)\n"
    | str replace --all $'"cwd":"($OLD)"' $'"cwd":"($NEW)"'
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

    rm --recursive --force $home

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

    rm --recursive --force $home

    assert str contains $top '"cwd":"/work/moved/demo"'
    assert not ($top | str contains '"cwd":"/work/demo"')
    assert str contains $sub '"cwd":"/work/moved/demo"'
}

@test
def "leaves the old path where it is a record of what happened" [] {
    let home = fake-home

    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let top = open --raw (projects-dir $home | path join "-work-moved-demo" "aaaa.jsonl")

    rm --recursive --force $home

    # A file the session read and a path quoted in a message are history, not a
    # pointer to the project — rewriting them would falsify the transcript.
    assert str contains $top '"file_path":"/work/demo/README.md"'
    assert str contains $top 'look at /work/demo/README.md'
}

@test
def "changes nothing in a record but the cwd bytes" [] {
    let home = fake-home

    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let lines = open --raw (projects-dir $home | path join "-work-moved-demo" "aaaa.jsonl") | lines

    rm --recursive --force $home

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

    rm --recursive --force $home

    assert str contains $history '"project":"/work/moved/demo"'
    # Both the `projects` key and the `githubRepoPaths` value carry the path.
    assert str contains $config '"/work/moved/demo": {'
    assert str contains $config '"/work/moved/demo"'
    assert not ($config | str contains '"/work/demo"')
}

@test
def "leaves an unrelated project alone" [] {
    let home = fake-home

    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let other_there = projects-dir $home | path join "-work-other" | path exists
    let history = open --raw ($home | path join ".claude" "history.jsonl")
    let config = open --raw ($home | path join ".claude.json")

    rm --recursive --force $home

    assert $other_there
    assert str contains $history '"project":"/work/other"'
    assert str contains $config '"/work/other"'
}

@test
def "rewrites cwd without a rename when the encoded name is unchanged" [] {
    let home = fake-home

    # `/work/demo` and `/work-demo` both encode to `-work-demo`: the directory
    # name is lossy, so this move has nothing to rename and cwds to fix.
    with-env {HOME: $home} { project-move $OLD "/work-demo" | ignore }
    let content = open --raw (projects-dir $home | path join "-work-demo" "aaaa.jsonl")

    rm --recursive --force $home

    assert str contains $content '"cwd":"/work-demo"'
}

@test
def "finds the sessions of a path with a dot as Claude Code names them" [] {
    let home = $nu.temp-dir | path join $"project-move-(random uuid)"
    # Claude Code turns every character but a letter or digit into `-`, so the
    # worktree path below lands in `-work-demo--claude-worktrees-x`.
    let session_dir = $home | path join ".claude" "projects" "-work-demo--claude-worktrees-x"

    mkdir $session_dir
    '{"type":"user","cwd":"/work/demo/.claude/worktrees/x"}' | save --raw ($session_dir | path join "aaaa.jsonl")
    with-env {HOME: $home} { project-move "/work/demo/.claude/worktrees/x" $NEW | ignore }
    let content = open --raw (projects-dir $home | path join "-work-moved-demo" "aaaa.jsonl")

    rm --recursive --force $home

    assert str contains $content '"cwd":"/work/moved/demo"'
}

# =============================================================================
# The awkward shapes a real ~/.claude can take
# =============================================================================

@test
def "moves a project whose path holds glob metacharacters" [] {
    let home = $nu.temp-dir | path join $"project-move-(random uuid)"
    let session_dir = $home | path join ".claude" "projects" "-work-demo-1-"

    mkdir $session_dir
    '{"type":"user","cwd":"/work/demo[1]"}' | save --raw ($session_dir | path join "aaaa.jsonl")
    with-env {HOME: $home} { project-move "/work/demo[1]" $NEW | ignore }
    let content = open --raw (projects-dir $home | path join "-work-moved-demo" "aaaa.jsonl")

    rm --recursive --force $home

    assert str contains $content '"cwd":"/work/moved/demo"'
}

@test
def "keeps the 0600 mode of the files it rewrites" [] {
    let home = fake-home

    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let config_mode = mode-of ($home | path join ".claude.json")
    let history_mode = mode-of ($home | path join ".claude" "history.jsonl")

    rm --recursive --force $home

    assert equal $config_mode "rw-------"
    assert equal $history_mode "rw-------"
}

# A transcript's mtime is what puts a project's sessions in order, so a move that
# lets `mv` stamp every one of them with the time of the move hands both
# `claude-nu sessions` and the `claude --resume` picker a shuffled history.
@test
def "keeps the mtime of the transcripts it rewrites" [] {
    let home = fake-home
    let was = "2026-01-02T03:04:05Z" | into datetime
    let sessions = projects-dir $home | path join "-work-demo"

    touch --modified --timestamp $was ($sessions | path join "aaaa.jsonl") ($sessions | path join "aaaa" "subagents" "agent-1.jsonl")
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let moved = projects-dir $home | path join "-work-moved-demo"
    let top = ls ($moved | path join "aaaa.jsonl") | get 0.modified
    let sub = ls ($moved | path join "aaaa" "subagents" "agent-1.jsonl") | get 0.modified

    rm --recursive --force $home

    assert equal $top $was
    assert equal $sub $was
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

    rm --recursive --force $home

    assert equal $still_link "symlink"
    assert str contains $content '"/work/moved/demo"'
}

@test
def "moves a project Claude knows only from its config" [] {
    let home = fake-home

    rm --recursive --force (projects-dir $home | path join "-work-demo")
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let config = open --raw ($home | path join ".claude.json")

    rm --recursive --force $home

    # No sessions directory to rename, so the rename must not be attempted —
    # `mv` on a missing source dies with a bare "Not found" and the plan would
    # have promised a move it could not make.
    assert equal ($report | get kind) [history config]
    assert str contains $config '"/work/moved/demo"'
}

@test
def "refuses a file it cannot read as text" [] {
    let home = fake-home

    0x[00 ff 22 63 77 64 22] | save --raw (projects-dir $home | path join "-work-demo" "cccc.jsonl")
    let failed = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }
    let untouched = open --raw (projects-dir $home | path join "-work-demo" "aaaa.jsonl")

    rm --recursive --force $home

    # A non-UTF8 transcript stops the move before anything is written.
    assert $failed
    assert str contains $untouched '"cwd":"/work/demo"'
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

    rm --recursive --force $home

    assert $died
    assert $still_old_name
    # The transcript already done reports no occurrences and drops out of the
    # second plan; what is left gets written, and then the rename happens.
    assert equal ($report | get kind) [sessions-dir session history config]
    assert str contains $top '"cwd":"/work/moved/demo"'
    assert str contains $sub '"cwd":"/work/moved/demo"'
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

    rm --recursive --force $home

    # The cwd rewrite only touches matching records, but `mv` takes the whole
    # directory: the co-located project's transcripts would land under the new
    # name while its own config entry still points at the old path.
    assert $failed
    assert $still_old_name
    assert str contains $ours '"cwd":"/work/demo"'
    assert str contains $theirs '"cwd":"/work-demo"'
}

@test
def "moves a transcript whose cwd is below the project" [] {
    let home = fake-home
    let shared = projects-dir $home | path join "-work-demo"

    # A subagent that ran `cd sub` keeps writing to the store of its session.
    '{"type":"user","cwd":"/work/demo/sub"}' | save --raw ($shared | path join "aaaa" "subagents" "agent-2.jsonl")
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let moved = open --raw (projects-dir $home | path join "-work-moved-demo" "aaaa" "subagents" "agent-2.jsonl")

    rm --recursive --force $home

    assert equal $moved '{"type":"user","cwd":"/work/moved/demo/sub"}'
}

@test
def "a move into a subdirectory of the project rewrites the root cwd once" [] {
    let home = fake-home

    with-env {HOME: $home} { project-move $OLD "/work/demo/inner" | ignore }
    let moved = open --raw (projects-dir $home | path join "-work-demo-inner" "aaaa.jsonl")

    rm --recursive --force $home

    assert str contains $moved '"cwd":"/work/demo/inner"'
    assert not ($moved | str contains '/inner/inner')
}

@test
def "still refuses a sibling whose path only starts with the project path" [] {
    let home = fake-home

    # `/work/demo-2` is not below `/work/demo`; it only shares the first letters.
    '{"type":"user","cwd":"/work/demo-2"}' | save --raw (projects-dir $home | path join "-work-demo" "cccc.jsonl")
    let failed = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }

    rm --recursive --force $home

    assert $failed
}

@test
def "moves past a session file that records no cwd" [] {
    let home = fake-home

    # Claude creates the session file when a session starts and writes nothing
    # to one that dies before its first turn. A real store holds these.
    "" | save --raw (projects-dir $home | path join "-work-demo" "dead.jsonl")
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let moved = projects-dir $home | path join "-work-moved-demo" | path exists

    rm --recursive --force $home

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

    rm --recursive --force $home

    # The new path alone in the config is our own work, not a second project —
    # reading it as a merge would make the move impossible to finish.
    assert equal ($report | get kind) [sessions-dir session session]
    assert str contains $content '"cwd":"/work/moved/demo"'
}

@test
def "refuses when the config already carries the destination" [] {
    let home = fake-home

    open --raw ($home | path join ".claude.json")
    | str replace '"/work/other": {}' '"/work/moved/demo": {"allowedTools": ["B"]}'
    | save --raw --force ($home | path join ".claude.json")
    let failed = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }
    let config = open --raw ($home | path join ".claude.json")

    rm --recursive --force $home

    # The swap is textual, so rewriting the old key here would leave `projects`
    # holding "/work/moved/demo" twice — JSON a parser still reads, keeping one
    # entry and silently dropping the other project's permissions.
    assert $failed
    assert str contains $config '"/work/demo"'
}

@test
def "dry-run reports the same rows and writes nothing" [] {
    let home = fake-home
    let plan = with-env {HOME: $home} { project-move $OLD $NEW --dry-run }
    let untouched = projects-dir $home | path join "-work-demo" | path exists
    let content = open --raw (projects-dir $home | path join "-work-demo" "aaaa.jsonl")

    rm --recursive --force $home

    assert $untouched
    assert str contains $content '"cwd":"/work/demo"'
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

    rm --recursive --force $home

    assert equal ($report | get kind) [sessions-dir session session history config]
    # Paths are reported where the artifact ends up, not where it was read from.
    assert equal ($report | where kind == sessions-dir | get 0.path | path basename) "-work-moved-demo"
}

# =============================================================================
# Folding into a store that already stands at the destination
# =============================================================================

@test
def "folds into a sessions directory already standing at the destination" [] {
    let home = fake-home
    # A project that moves twice comes back to a name Claude already knows, so
    # this is the normal end state, not a mistake to refuse.
    let dst = seed-destination $home "cccc.jsonl" '{"type":"user","cwd":"/work/moved/demo"}'
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let old_gone = not (projects-dir $home | path join "-work-demo" | path exists)
    let names = ls $dst | get name | path basename | sort
    let top = open --raw ($dst | path join "aaaa.jsonl")

    rm --recursive --force $home

    assert $old_gone
    assert equal $names [aaaa aaaa.jsonl cccc.jsonl]
    assert str contains $top '"cwd":"/work/moved/demo"'
    assert equal ($report | get kind) [sessions-fold session session history config]
}

@test
def "drops a source copy the destination already holds whole" [] {
    let home = fake-home
    let both = rewritten $USER_LINE $ASSISTANT_LINE
    let dst = seed-destination $home "aaaa.jsonl" $both
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let content = open --raw ($dst | path join "aaaa.jsonl")

    rm --recursive --force $home

    assert equal ($report | where kind == keep-destination | get path | path basename) [aaaa.jsonl]
    # No `session` row for it either: rewriting the cwd of a file that is about
    # to be deleted would be work reported on nothing.
    assert equal ($report | where kind == session | get path | path basename) ["agent-1.jsonl"]
    assert equal $content $both
}

@test
def "keeps the source copy when it continues the destination one" [] {
    let home = fake-home
    # A transcript is append-only JSONL, so the destination holding the same
    # session one turn shorter means the source copy is that conversation later
    # in its life — not a disagreement about it.
    let dst = seed-destination $home "aaaa.jsonl" (rewritten $USER_LINE)
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let content = open --raw ($dst | path join "aaaa.jsonl")

    rm --recursive --force $home

    assert equal ($report | where kind == keep-source | get path | path basename) [aaaa.jsonl]
    assert equal $content (rewritten $USER_LINE $ASSISTANT_LINE)
}

@test
def "keeps the destination copy when it is the one that continues" [] {
    let home = fake-home
    let both = rewritten $USER_LINE $ASSISTANT_LINE
    let dst = seed-destination $home "aaaa.jsonl" $both

    # Now the source is the shorter one, so the same rule points the other way.
    $"($USER_LINE)\n" | save --raw --force (projects-dir $home | path join "-work-demo" "aaaa.jsonl")
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let content = open --raw ($dst | path join "aaaa.jsonl")

    rm --recursive --force $home

    assert equal ($report | where kind == keep-destination | get path | path basename) [aaaa.jsonl]
    assert equal $content $both
}

@test
def "folds a file that is not a transcript by the same containment rule" [] {
    let home = fake-home
    let memory = projects-dir $home | path join "-work-demo" "memory"

    mkdir $memory
    "- [one](one.md)\n- [two](two.md)\n" | save --raw ($memory | path join "MEMORY.md")
    let dst = seed-destination $home ("memory" | path join "MEMORY.md") "- [one](one.md)\n"

    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let index = open --raw ($dst | path join "memory" "MEMORY.md")

    rm --recursive --force $home

    # A store holds more than transcripts, and the memory index grows the same
    # way — by appending lines. The rule settles it without knowing the format,
    # which is why the fold compares bytes and not JSON.
    assert equal $index "- [one](one.md)\n- [two](two.md)\n"
}

@test
def "does not resolve a file by a rewrite that will never happen to it" [] {
    let home = fake-home

    # Only transcripts get their cwd swapped. A file that is not one keeps its
    # bytes, so predicting the swap on it would compare the destination against
    # a source that never exists — and here that comparison would come back
    # "identical", deleting a copy the destination does not hold.
    '{"cwd":"/work/demo"}' | save --raw (projects-dir $home | path join "-work-demo" "notes.txt")
    seed-destination $home "notes.txt" '{"cwd":"/work/moved/demo"}' | ignore
    let failed = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }
    let survived = open --raw (projects-dir $home | path join "-work-demo" "notes.txt")

    rm --recursive --force $home

    assert $failed
    assert equal $survived '{"cwd":"/work/demo"}'
}

@test
def "drops a source copy the destination holds verbatim with the old cwd" [] {
    let home = fake-home
    # What a snapshot restore leaves behind: the store under its new name holds
    # the same bytes as the old one, the old cwd included.
    let verbatim = [$USER_LINE $ASSISTANT_LINE] | str join "\n" | $"($in)\n"
    let dst = seed-destination $home "aaaa.jsonl" $verbatim
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let content = open --raw ($dst | path join "aaaa.jsonl")

    rm --recursive --force $home

    assert equal ($report | where kind == keep-destination | get path | path basename) [aaaa.jsonl]
    assert equal $content (rewritten $USER_LINE $ASSISTANT_LINE)
}

@test
def "rewrites an old cwd the destination store still records" [] {
    let home = fake-home
    let dst = seed-destination $home "cccc.jsonl" $"($SUBAGENT_LINE)\n"
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let content = open --raw ($dst | path join "cccc.jsonl")

    rm --recursive --force $home

    assert equal ($report | where kind == session | get path | path basename | sort) [aaaa.jsonl agent-1.jsonl cccc.jsonl]
    assert equal $content (rewritten $SUBAGENT_LINE)
}

@test
def "refuses a pair where neither copy contains the other" [] {
    let home = fake-home

    seed-destination $home "aaaa.jsonl" '{"type":"user","cwd":"/work/moved/demo","message":"a different conversation"}' | ignore
    let failed = try { with-env {HOME: $home} { project-move $OLD $NEW }; false } catch { true }
    let untouched = open --raw (projects-dir $home | path join "-work-demo" "aaaa.jsonl")

    rm --recursive --force $home

    # Two copies that genuinely disagree are the one case no rule settles, and a
    # flag that deleted one side would make exactly the wrong call easy. The
    # conflict is found while planning, so nothing has been written yet.
    assert $failed
    assert str contains $untouched '"cwd":"/work/demo"'
}

@test
def "dry-run reports the fold without writing it" [] {
    let home = fake-home
    let dst = seed-destination $home "aaaa.jsonl" (rewritten $USER_LINE)
    let plan = with-env {HOME: $home} { project-move $OLD $NEW --dry-run }
    let still_old_name = projects-dir $home | path join "-work-demo" | path exists
    let untouched = open --raw ($dst | path join "aaaa.jsonl")

    rm --recursive --force $home

    assert $still_old_name
    assert equal $untouched (rewritten $USER_LINE)
    assert equal ($plan | get kind) [sessions-fold keep-source session session history config]
}

@test
def "refuses when no state exists for the old path" [] {
    let home = fake-home
    let failed = try { with-env {HOME: $home} { project-move "/work/nothing" $NEW }; false } catch { true }

    rm --recursive --force $home

    assert $failed
}

@test
def "refuses a move that goes nowhere" [] {
    let home = fake-home
    # A trailing slash is the same directory; `cwd` never carries one.
    let failed = try { with-env {HOME: $home} { project-move $OLD "/work/demo/" }; false } catch { true }

    rm --recursive --force $home

    assert $failed
}

# =============================================================================
# Links into the store
# =============================================================================

# A link the way Claude Code writes one for a session that continues `aaaa`:
# `<store>/<session>/subagents/agent-1.jsonl`, by absolute path, to the agent
# transcript in `aaaa`.
def link-agent [home: path store: string session: string]: nothing -> path {
    let target = projects-dir $home | path join "-work-demo" "aaaa" "subagents" "agent-1.jsonl"
    let link = projects-dir $home | path join $store $session "subagents" "agent-1.jsonl"

    mkdir ($link | path dirname)
    ^ln -s $target $link
    $link
}

def link-target [link: path]: nothing -> string {
    ls --long $link | get 0.target
}

@test
def "retargets a link inside the store to the moved store" [] {
    let home = fake-home

    link-agent $home "-work-demo" "dddd" | ignore
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let moved = projects-dir $home | path join "-work-moved-demo"
    let link = $moved | path join "dddd" "subagents" "agent-1.jsonl"
    let target = link-target $link
    let readable = open --raw $link | str contains '"cwd":"/work/moved/demo"'

    rm --recursive --force $home

    assert equal $target ($moved | path join "aaaa" "subagents" "agent-1.jsonl")
    assert $readable
    assert equal ($report | where kind == link | get path) [$link]
}

@test
def "retargets a link another store holds into the moved store" [] {
    let home = fake-home
    let link = link-agent $home "-work-other" "eeee"
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let target = link-target $link

    rm --recursive --force $home

    assert equal $target (projects-dir $home | path join "-work-moved-demo" "aaaa" "subagents" "agent-1.jsonl")
    assert equal ($report | where kind == link | get path) [$link]
}

@test
def "plans the file behind a link once" [] {
    let home = fake-home

    link-agent $home "-work-demo" "dddd" | ignore
    let report = with-env {HOME: $home} { project-move $OLD $NEW --dry-run }

    rm --recursive --force $home

    assert equal ($report | where kind == session | get path | path basename) [aaaa.jsonl agent-1.jsonl]
}

@test
def "repairs a link that an earlier move left pointing into the old store" [] {
    let home = fake-home
    let old_target = link-agent $home "-work-demo" "dddd" | link-target $in

    # A move that ran before links were retargeted: the store is at its new
    # name, every other trace of the old path is gone, the link still points
    # into the old store.
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let moved_link = projects-dir $home | path join "-work-moved-demo" "dddd" "subagents" "agent-1.jsonl"

    ^ln -s -f -n $old_target $moved_link
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let readable = $moved_link | path exists

    rm --recursive --force $home

    assert equal ($report | get kind) [link]
    assert $readable
}

@test
def "drops a source link the destination store already holds as a file" [] {
    let home = fake-home

    link-agent $home "-work-demo" "dddd" | ignore
    let dst = seed-destination $home ("dddd" | path join "subagents" "agent-1.jsonl") (rewritten $SUBAGENT_LINE)
    let report = with-env {HOME: $home} { project-move $OLD $NEW }
    let kept = $dst | path join "dddd" "subagents" "agent-1.jsonl"
    let still_file = ($kept | path type) == "file"

    rm --recursive --force $home

    assert $still_file
    assert equal ($report | where kind == keep-destination | get path) [$kept]
    assert equal ($report | where kind == link) []
}

@test
def "retargets a link to a directory and not the files in it" [] {
    let home = fake-home
    # The shape of a workflow run resumed in another session:
    # `<session>/subagents/workflows/wf_*` links to the run's directory.
    let run = projects-dir $home | path join "-work-demo" "aaaa" "subagents" "workflows" "wf_1"
    let link = projects-dir $home | path join "-work-demo" "dddd" "subagents" "workflows" "wf_1"

    mkdir $run ($link | path dirname)
    '{"type":"user","cwd":"/work/demo"}' | save --raw ($run | path join "agent-2.jsonl")
    ^ln -s $run $link
    with-env {HOME: $home} { project-move $OLD $NEW | ignore }
    let moved = projects-dir $home | path join "-work-moved-demo"
    let moved_link = $moved | path join "dddd" "subagents" "workflows" "wf_1"
    let target = ls --long --directory $moved_link | get 0.target
    let inside = ls $moved_link | get name | path basename

    rm --recursive --force $home

    assert equal $target ($moved | path join "aaaa" "subagents" "workflows" "wf_1")
    # `ln -n`: the old link is replaced, not given a new link inside its target.
    assert equal $inside [agent-2.jsonl]
}
