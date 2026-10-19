# claude-nu project-move: point Claude Code's stored state at a project's new
# location. Claude keys everything by the absolute project path, so a directory
# moved with `mv` leaves its sessions, its permissions and its prompt history
# stranded under the old name. This retargets the four places that path is
# written, and nothing else — the project directory itself is the user's to move.
#
# Why a literal substring swap and not a JSON round trip: a session record is a
# line of JSON we did not author. Parsing and re-emitting it rewrites every byte
# of every record — escaping, key order, how numbers are spelled — in order to
# change one field. Swapping the exact fragment `"cwd":"<old>"` touches only the
# bytes that encode the path. Measured on one 62-line session: the path occurs 65
# times, 45 of them as that fragment; the other 20 sit inside message texts and
# tool arguments, where they record what happened at the old location and must
# stay as written. A cwd below the old path, `"cwd":"<old>/`, is swapped too:
# see `cwd-swaps`.

use discovery.nu [projects-root encode-project-dir]

# ~/.claude.json — global config; `projects` is keyed by absolute path, and
# `githubRepoPaths` lists the same path as a value.
# Why `path expand`: on a symlinked dotfile `ls` reports the link's own mtime,
# which never changes, so the concurrency check below would be a permanent no-op
# and `mv` would replace the link with a plain file. Resolving up front means we
# read, guard and write the same real file.
def claude-config []: nothing -> path {
    $env.HOME | path join ".claude.json" | path expand
}

# ~/.claude/history.jsonl — the REPL prompt history, one JSON line per prompt,
# each tagged with the project it was typed in.
def prompt-history []: nothing -> path {
    $env.HOME | path join ".claude" "history.jsonl" | path expand
}

# The absolute path spelling Claude records in `cwd`.
# Not plain `path expand` because: the old directory no longer exists and the new
# one may not exist yet, so nothing may be resolved through the filesystem, and
# `path expand` keeps a trailing slash that `cwd` never has.
def normalize-project-path []: path -> path {
    let expanded = $in | path expand --no-symlink | str trim --right --char '/'

    if ($expanded | is-empty) { "/" } else { $expanded }
}

# Every JSONL under `dir`, at any depth — both the top-level `<uuid>.jsonl` and
# the subagent transcripts nested under `<uuid>/subagents/`.
# Not `glob` because: this directory name is built from the project path, so a
# project path holding `[`, `*` or `?` becomes a pattern that matches nothing —
# every session would drop out of the plan while the move went ahead anyway.
# A path held in a variable is literal to `ls`, so the walk is spelled out.
# Not `discover-session-files` because: it filters names by the UUID pattern,
# and a `cwd` needs rewriting whatever the file is called.
# Why a symlink is skipped: its target is a transcript of its own. In this store
# that file is rewritten where it lies; in another store it belongs to another
# project.
def jsonl-files [dir: path]: nothing -> list<path> {
    ls $dir
    | each {|entry|
        if $entry.type == "dir" {
            jsonl-files $entry.name
        } else if $entry.type == "symlink" {
            []
        } else {
            [($entry.name | path expand)]
        }
    }
    | flatten
    | where $it ends-with ".jsonl"
}

# Every file under `dir`, at any depth, as a path relative to `dir`.
# Not `glob`, for the same reason as `jsonl-files`: the directory name is built
# from the project path, so a `[` in it turns the walk into a pattern matching
# nothing. Every file, not just `.jsonl` — a store also holds `memory/` and
# whatever else Claude drops in there, and all of it has to relocate.
def relative-files [dir: path]: nothing -> list<string> {
    ls $dir
    | each {|entry|
        if $entry.type == "dir" {
            relative-files $entry.name | each {|rel| [($entry.name | path basename) $rel] | path join }
        } else {
            [($entry.name | path basename)]
        }
    }
    | flatten
}

# A file's bytes as text.
# Why the explicit `into string`: `open --raw` yields a byte stream, and one that
# is not valid UTF-8 splits into a single chunk — count 0 — so the file would
# vanish from the plan while `str replace` on the same bytes throws at write
# time. Converting first turns "not text" into an error naming the file.
def read-text [file: path]: nothing -> string {
    try {
        open --raw $file | into string
    } catch {
        error make {msg: $"($file) is not valid UTF-8 — claude-nu will not guess at its bytes"}
    }
}

# How many times `needle` occurs in the text piped in.
def count-of [needle: string]: string -> int {
    ($in | split row $needle | length) - 1
}

# How many times `needle` occurs in a file.
def count-in-file [file: path needle: string]: nothing -> int {
    read-text $file | count-of $needle
}

# Byte-exact swap, written through a temp file beside the target so an
# interrupted run cannot leave a half-written session behind.
# Why the temp starts as a copy: `cp` carries the target's mode across, and both
# ~/.claude.json (which holds the account email and machine id) and history.jsonl
# are 0600 — a temp created fresh would come back 0644 through the umask. `save`
# then truncates that copy and writes the new bytes into it.
# Why the mtime check: ~/.claude.json and history.jsonl are rewritten whole by
# every running `claude`, so a session that saves between our read and our write
# would lose its change without a trace. Comparing the mtime we read against the
# one on disk turns that silent loss into an error. It leaves a window of the few
# milliseconds between the check and the `mv`; the alternative is a lock file
# Claude itself does not take.
# Why the mtime is then put back: a transcript's mtime is what puts a project's
# sessions in order — `claude-nu sessions` sorts by it (discovery.nu), and the
# `claude --resume` picker went shuffled after a real move, so it reads the same
# field. `mv` stamps every file it lands with the time of the move, which
# collapses a whole project's history into one second. The mtime of a transcript
# means "when this conversation last spoke", and a retarget does not change that.
# The same touch also lands on ~/.claude.json and history.jsonl: nothing is known
# to order by their mtime, and a special case would cost more than the uniformity
# buys.
def swap-in-file [file: path swaps: table<needle: string, replacement: string>]: nothing -> nothing {
    let before = ls $file | get 0.modified
    let tmp = $"($file).claude-nu-move"

    cp $file $tmp
    $swaps
    | reduce --fold (open --raw $file | into string) {|swap text|
        $text | str replace --all --no-expand $swap.needle $swap.replacement
    }
    | save --raw --force $tmp
    if (ls $file | get 0.modified) != $before {
        rm --force $tmp
        error make {msg: $"($file) changed while claude-nu was rewriting it — nothing was written to it; rerun the move"}
    }
    mv --force $tmp $file
    touch --modified --timestamp $before $file
}

# Stop a rename that would drag a second project's sessions along.
# Encoding is lossy — `/work/demo` and `/work-demo` both become `-work-demo` —
# so one directory can hold two projects' transcripts. The cwd rewrite touches
# only the matching records, but `mv` moves the whole directory: the co-located
# project would land under the new name while its own `~/.claude.json` entry
# still points at the old path, stranded, with nothing in the report saying so.
# Why a file holding the *new* cwd is not foreign: a run that died after
# rewriting some transcripts leaves exactly that, and rerunning it must finish
# the move instead of mistaking its own work for a stranger's.
# Why a file recording no cwd at all is not foreign either: Claude creates a
# session file when a session starts and writes nothing to one that dies before
# its first turn — this store holds such a zero-byte transcript today. It points
# at no project, so it strands nothing, and reading it as a stranger's would
# refuse a move nobody can then make.
def refuse-shared-dir [scanned: table src: path old: path]: nothing -> nothing {
    let foreign = $scanned
        | where scan.records_cwd and scan.old == 0 and scan.new == 0
        | sort-by source

    if ($foreign | is-not-empty) {
        let file = $foreign | get 0.source
        # Re-read on the error path only: the scan keeps a substring test, which
        # a 185 MB store can afford per file where a regex over every one cannot.
        let cwd = read-text $file | parse --regex '"cwd":"([^"]*)"' | get 0.capture0

        error make {msg: $"($src) holds sessions for more than one project: ($file) records ($cwd), not ($old). The encoded directory name is lossy, so both projects share it — renaming it would carry those transcripts to the new name while the entry that points at them keeps the old path."}
    }
}

# Which copy of a file that exists in both stores survives.
# A transcript is append-only JSONL, so two copies of one session differ by one
# being an earlier, shorter version of the other — the longer one is the whole
# conversation. Identical falls out of the same test, which is why there is no
# third verdict for it. Only a pair where neither copy contains the other is a
# real disagreement, and that one is not ours to resolve.
def fold-verdict [from: binary to: binary]: nothing -> string {
    if ($to | bytes starts-with $from) {
        "keep-destination"
    } else if ($from | bytes starts-with $to) {
        "keep-source"
    } else {
        "conflict"
    }
}

# The swaps applied to bytes, as `swap-in-file` will apply them to the text.
def swap-bytes [swaps: table]: binary -> binary {
    let bytes = $in

    $swaps
    | reduce --fold $bytes {|swap acc|
        $acc | bytes replace --all ($swap.needle | into binary) ($swap.replacement | into binary)
    }
}

# Plan rows for the files that exist in both stores.
# Why a fold and not a refusal: a project that moves twice comes back to a name
# Claude already knows, so a collision is the normal end state, not a mistake.
# The question worth asking is not "does the destination exist" but "does it hold
# anything the source doesn't" — and that is computed, not asked of the user.
def plan-fold [src: path dst: path rewriting: list<string> dst_rewriting: list<string> swaps: table]: nothing -> table {
    relative-files $src
    | where ($dst | path join $it | path exists)
    | sort
    | each {|rel|
        let from = $src | path join $rel
        let to = $dst | path join $rel

        # Why a link always yields: it stands for a transcript another session
        # holds, and the destination already has a file of that name — the same
        # agent id, so the same transcript. Moved over it, the link would
        # replace a real file with a pointer.
        if ($from | path type) == "symlink" {
            return {kind: "keep-destination" path: $to replaced: null source: $from swaps: null}
        }

        # Compared as the source will look after its cwd swap, not as it looks
        # now: the swap runs first, so comparing the current bytes would resolve
        # a pair that never exists on disk. Which is also why the swap is applied
        # only to the files that will really get it — a store holds more than
        # transcripts, and predicting a rewrite that never happens can drop a
        # source copy the destination does not actually contain.
        # Byte-level rather than text, because this walks every file and only
        # transcripts are known to be UTF-8.
        let after = open --raw $from
            | into binary
            | if $from in $rewriting { swap-bytes $swaps } else { }
        # The destination is compared as it will look too: a copy that still
        # records the old cwd gets the same swap before anything is folded.
        let target = open --raw $to
            | into binary
            | if $to in $dst_rewriting { swap-bytes $swaps } else { }
        let verdict = fold-verdict $after $target

        if $verdict == "conflict" {
            error make {msg: $"($rel) exists in both stores and neither copy contains the other: ($from) and ($to). Nothing was written — settle that file by hand, then rerun."}
        }
        {kind: $verdict path: $to replaced: null source: $from swaps: null}
    }
}

# The fragments a session record spells its cwd with: the project root, and any
# directory below it.
# Why the subdirectory form: an agent that runs `cd` inside a session keeps
# writing to the same store, so a subagent transcript records `<old>/sub` while
# it belongs to this project. A session started in `<old>/sub` gets a store of its
# own (`-old-sub`) and never lands here, so the prefix cannot catch a stranger.
# Not one prefix `"cwd":"<old>` because: it would also match `<old>-2`, a sibling.
def cwd-swaps [old: path new: path]: nothing -> table<needle: string, replacement: string> {
    let root = [{needle: $'"cwd":"($old)"' replacement: $'"cwd":"($new)"'}]

    # Why: when the new path is below the old one, the prefix needle also
    # matches the new root, so a cwd just rewritten would be rewritten again —
    # and a rerun cannot tell a finished root from an untouched subdirectory.
    # Such a move keeps refusing a subdirectory cwd as foreign.
    if ($new | str starts-with $"($old)/") {
        $root
    } else {
        $root | append {needle: $'"cwd":"($old)/' replacement: $'"cwd":"($new)/'}
    }
}

# Plan rows for the sessions directory: the relocation itself, plus every JSONL
# under it that records the old cwd. `source` is where the file is read and
# written now; `path` is where it ends up, since the relocation comes last.
def plan-sessions [src: path dst: path old: path new: path]: nothing -> table {
    if not ($src | path exists) { return [] }

    let swaps = cwd-swaps $old $new
    # One read per file: the old-cwd count drives the plan, while the new-cwd
    # count and `records_cwd` are what tell a half-finished rerun and a session
    # that never started apart from a shared directory below.
    let scanned = jsonl-files $src
        | wrap source
        | insert scan {|row|
            let text = read-text $row.source

            {
                old: ($swaps | each {|swap| $text | count-of $swap.needle } | math sum)
                new: ($swaps | each {|swap| $text | count-of $swap.replacement } | math sum)
                records_cwd: ($text | str contains '"cwd":"')
            }
        }

    # Only the relocation can strand another project, so a move that keeps the
    # encoded name has nothing to refuse — it just rewrites cwds in place.
    if $src != $dst { refuse-shared-dir $scanned $src $old }

    # Checked after the shared-directory refusal: a store holding a second
    # project is the wrong store to fold anywhere, and that is the error worth
    # showing first.
    let folding = $src != $dst and ($dst | path exists)
    let rewriting = $scanned | where scan.old > 0 | get source
    # Why the destination is scanned too: a store restored from a snapshot taken
    # before an earlier move is a verbatim copy that still records the old cwd.
    # Compared as it stands, it made two byte-identical copies a conflict, and
    # whatever the fold kept there went on pointing at the old path.
    let dst_scanned = if $folding {
        jsonl-files $dst
        | wrap source
        | insert old {|row|
            let text = read-text $row.source

            $swaps | each {|swap| $text | count-of $swap.needle } | math sum
        }
        | where old > 0
    } else { [] }
    let fold = if $folding { plan-fold $src $dst $rewriting $dst_scanned.source $swaps } else { [] }
    # A copy the destination already contains whole is deleted, not moved, so
    # rewriting its cwd first would be work reported on a file about to vanish.
    let dropped = $fold | where kind == "keep-destination" | get source

    let files = $scanned
        | where scan.old > 0
        | where source not-in $dropped
        | insert kind "session"
        | insert path {|row| $row.source | str replace $src $dst }
        | insert replaced {|row| $row.scan.old }
        | insert swaps {|_| $swaps }
        | select kind path replaced source swaps
        # A destination copy the source replaces is overwritten, so its rewrite
        # would be work reported on a file about to vanish.
        | append (
            $dst_scanned
            | where source not-in ($fold | where kind == "keep-source" | get path)
            | each {|row| {kind: "session" path: $row.source replaced: $row.old source: $row.source swaps: $swaps} }
        )
        # `ls` yields no defined order, and a report that reshuffles between two
        # runs of the same move is hard to read and hard to diff.
        | sort-by path

    # A move between two paths that encode to the same directory name has
    # nothing to relocate, only cwds to rewrite.
    if $src == $dst {
        $files
    } else {
        let relocation = if $folding { "sessions-fold" } else { "sessions-dir" }

        [{kind: $relocation path: $dst replaced: null source: $src swaps: null}]
        | append $fold
        | append $files
    }
}

# Plan rows for the symlinks that point into the moving store: `path` is where
# the link ends up, `target` what it points at after the move.
# Why: Claude Code gives a session that continues another one links to the
# subagent transcripts and workflow directories of that session, by absolute
# path. A store that moves leaves each such link pointing at a directory that is
# gone, and a reader that lists the link then fails to open it.
# Why the whole projects root and not `src` alone: a session resumed from
# another project links into this store from outside it.
# Why `glob` here, unlike `jsonl-files`: the pattern is the projects root, built
# from HOME; the encoded project names below it are matched by `**`, never
# parsed as a pattern.
def plan-links [src: path dst: path]: nothing -> table {
    if $src == $dst { return [] }

    glob (projects-root | path join "**") --no-dir --no-file
    | each {|link| ls --long --directory $link | get 0 }
    | where target starts-with $"($src)/"
    | sort-by name
    | each {|link|
        let path = if ($link.name | str starts-with $"($src)/") {
            $link.name | str replace $src $dst
        } else {
            $link.name
        }

        {kind: "link" path: $path replaced: null source: $link.name swaps: null target: ($link.target | str replace $src $dst)}
    }
}

# Move the source store into a destination store that already exists, file by
# file, applying the verdicts the plan settled. A directory rename cannot merge,
# and every file here is either already accounted for at the destination or has
# a name no destination file holds.
def fold-into [src: path dst: path plan: table]: nothing -> nothing {
    let dropped = $plan | where kind == "keep-destination" | get source

    relative-files $src
    | each {|rel|
        let from = $src | path join $rel

        if $from in $dropped {
            rm --force $from
        } else {
            let to = $dst | path join $rel

            mkdir ($to | path dirname)
            # A rename inside one directory tree, so the mtime that orders a
            # project's sessions survives without being put back by hand.
            mv --force $from $to
        }
    }

    # What is left has to be empty directories. Anything else means the plan and
    # the tree disagree, and a recursive delete under ~/.claude must not run on
    # the assumption that they don't.
    if (relative-files $src | is-not-empty) {
        error make {msg: $"($src) still holds files after the fold — it was left in place"}
    }
    rm --recursive --force $src
}

# Plan row for a single file whose path references are a quoted JSON string.
def plan-swap [file: path kind: string needle: string replacement: string]: nothing -> table {
    if not ($file | path exists) { return [] }
    let hits = count-in-file $file $needle

    if $hits == 0 {
        []
    } else {
        [{kind: $kind path: $file replaced: $hits source: $file swaps: [{needle: $needle replacement: $replacement}]}]
    }
}

# Retarget Claude Code's stored state from one project path to another.
#
# Both arguments are real paths on disk, not encoded directory names. The
# project directory is expected to have been moved already — this command only
# fixes what Claude wrote about it: the sessions directory name, the `cwd` field
# in every session record, every mention of the path in ~/.claude.json (its
# `projects` key and its `githubRepoPaths` entry), and the `project` field in the
# prompt history.
#
# Occurrences of the old path inside message texts and tool arguments are left
# alone: they are a record of what happened, not a pointer to the project.
# A `cwd` below the old path, written when a session ran `cd`, moves with it.
# Projects nested under the old path (git worktrees, for instance) are separate
# projects and are not moved with it.
#
# A sessions directory already standing at the destination is folded into rather
# than refused — a project that moves twice comes back to a name Claude knows.
# A file present in both stores is resolved by containment: a transcript is
# append-only, so the copy that contains the other is the whole one and wins
# (`keep-source` or `keep-destination`). A pair where neither contains the other
# stops the run before anything is written.
#
# Returns one row per artifact touched; `--dry-run` returns the same rows and
# writes nothing.
@category claude-nu
@example "see what a move would touch" { claude-nu project-move ~/old/proj ~/new/proj --dry-run }
export def main [
    from: path # project path Claude has state for (the old location)
    to: path # where the project lives now
    --dry-run # report what would change and write nothing
]: nothing -> table {
    let old = $from | normalize-project-path
    let new = $to | normalize-project-path

    if $old == $new {
        error make {
            msg: $"Nothing to move: both paths normalize to ($old)"
            labels: [
                {text: "this path" span: (metadata $from).span}
                {text: "...and this one name the same project" span: (metadata $to).span}
            ]
            help: "give the old location first and the new one second; a project already at its new path has nothing to retarget"
        }
    }

    let src = projects-root | path join ($old | encode-project-dir)
    let dst = projects-root | path join ($new | encode-project-dir)
    let config = claude-config
    # A sessions directory already standing at the destination is not refused: it
    # is folded into, file by file, because two copies of a transcript resolve
    # themselves (see `fold-verdict`). Two config entries do not. The swap is
    # textual, so rewriting the old key when the new one is already there leaves
    # `projects` holding the same key twice — JSON a parser still reads, keeping
    # one entry and dropping the other's permissions — and there is no
    # append-only rule that picks a winner for `allowedTools` or a trust flag.
    #
    # Why both paths must be present for this to be a merge: the config swap is
    # the last write before the rename, so a run that died in between leaves the
    # config carrying the new path and nothing else. That is our own work, not a
    # second project — and `plan-swap` drops the row at zero hits anyway, so the
    # rerun simply finishes what is left.
    let merges_config = (
        ($config | path exists)
        and (count-in-file $config $'"($new)"') > 0
        and (count-in-file $config $'"($old)"') > 0
    )

    if $merges_config {
        # The two entries are printed rather than diffed: which side wins is a
        # judgement per field, so the useful thing to hand over is both records.
        error make {msg: ([
            $"($config) already has an entry for ($new) — merging two settings records is not this command's job."
            "Read both, fold them into one by hand, then rerun:"
            $"  open ($config) | get projects | get \"($old)\""
            $"  open ($config) | get projects | get \"($new)\""
        ] | str join "\n")}
    }

    let sessions = plan-sessions $src $dst $old $new
    # A link the fold deletes needs no new target.
    let dropped = $sessions | where kind == "keep-destination" | get source
    let plan = [
        $sessions
        (plan-links $src $dst | where source not-in $dropped)
        (plan-swap (prompt-history) "history" $'"project":"($old)"' $'"project":"($new)"')
        (plan-swap $config "config" $'"($old)"' $'"($new)"')
    ] | flatten

    if ($plan | is-empty) {
        error make {
            msg: $"No Claude Code state found for ($old)"
            label: {text: "no sessions, history or config entry under this path" span: (metadata $from).span}
            help: "Claude stores state per project cwd, so the old path has to be spelled as the project was opened"
        }
    }
    if $dry_run {
        return ($plan | reject --optional source swaps target)
    }

    $plan | where swaps != null | each {|row| swap-in-file $row.source $row.swaps }

    # Relocate last, so that a run which dies partway can be finished by running
    # it again: the sessions are still under the old name, the files already
    # rewritten report zero occurrences and drop out of the next plan, and what
    # is left gets done. It is also gated on the plan: a project Claude knows
    # only from its config has no directory to move.
    if "sessions-dir" in $plan.kind { mv $src $dst }
    if "sessions-fold" in $plan.kind { fold-into $src $dst $plan }

    # After the relocation, because a link inside the store is only at its new
    # `path` once the store has moved. A run that dies before this line leaves
    # links still pointing into the old store, and a rerun plans them again.
    # Not `--symbolic --force --no-dereference` because: the BSD ln of macOS has
    # no long flags. `-n` replaces a link to a directory instead of writing a
    # new link inside that directory.
    $plan | where kind == "link" | each {|row| ^ln -s -f -n $row.target $row.path }

    $plan | reject --optional source swaps target
}
