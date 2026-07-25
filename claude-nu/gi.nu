# gi — the gi protocol: seeded per repo, activated per session at launch.
#
# The gi protocol moves all "what/why" into git: the diff and the commit body
# carry the record, the chat carries almost nothing. Two commands, and the split
# between them is the whole design:
#
#   gi enable          seeds files into the repo — the Canvas output style, the
#                      gi skills, a working doc (the canvas). Writes nothing to
#                      settings, turns nothing on.
#   gi open / resume   launches Claude Code bound to one canvas: `--settings`
#                      carries the output style and the Stop hook for that launch
#                      alone, and $env.GI_CANVAS names the canvas. Both reach the
#                      hook, which runs as a child of that session. A canvas holds
#                      one session for life — open mints its id and writes it into
#                      the canvas, resume reads it back.
#
# Why activation lives at launch and not in .claude/settings.local.json (which
# is what this replaced): outputStyle, hooks, and env in a settings file are
# repo-wide and load into EVERY session in the repo. A canvas opened yesterday
# kept shaping unrelated sessions today, and the only cure was remembering to
# run `gi disable`. With per-launch activation there is no state to forget: a
# plain `claude` in a gi-seeded repo is a plain session, always.
#
# The style is proactive shaping only — it rests on prose, and the agent drifts
# back to long chat answers. The Stop hook is the structural floor under it: it
# blocks the turn when the final chat message is more than `done`/`noted` or a
# short pointer, and blocks turns ending on main/master (gi commits are internal
# working history — they reach a public branch only squash-merged, after
# finalization). It comes with every `gi open`/`gi resume`; `--no-hook` opens a
# canvas with the style alone.
#
# There is no `gi disable` and no migration path: gi writes to no settings file,
# so there is nothing to switch off. A repo set up by the older, repo-wide gi
# keeps working from its own settings until those keys are deleted by hand.

use sessions.nu [export-session resolve-session-file]

# The output-style name gi passes to `claude --settings` at launch. Matches the
# `name:` frontmatter in the seeded style file — outputStyle names a style, and
# Claude Code resolves it against .claude/output-styles in the launch directory,
# so the two must agree or the launch is silently style-less.
const GI_STYLE = "Canvas"

# Absolute path to this module's directory, resolved at parse time. Why a const:
# `path self` only runs at parse time, and the hook needs an absolute `use`
# target — relative paths are not resolved when Claude Code runs the hook.
# Deliberately NOT symlink-resolved: `path self` keeps the path as imported,
# and under cozy that is `~/repos/claude-nu` — the stable module path across
# machine states (vendored snapshot, sync-repos clone, dev-link symlink to the
# workspace). Resolving would pin the hook to one physical checkout and break
# the moment the settings file is used where that checkout does not exist;
# following the symlink at run time is exactly the dev-link contract.
const GI_MODULE_DIR = (path self | path dirname)

# The working-doc seed. A const of its own because two callers need it and only
# one of them has a repo root: gi-paths bundles it for enable, gi-import-text
# reads it with no root in hand.
const GI_HEADER_SRC = ($GI_MODULE_DIR | path join "gi-md-src" "canvas-header.md")

# The shell command Claude Code runs for the Stop event. Single-quote the `-c`
# body so the outer shell does not expand `$in`; `--stdin` feeds the event JSON
# to nushell as `$in`. The absolute module path is required — relative paths are
# not resolved at hook time.
const GI_COMMAND = $"nu --stdin -c 'use \"($GI_MODULE_DIR)\"; $in | claude-nu gi check'"

# The settings gi hands to `claude` at launch. Verified against the CLI:
# --settings takes a JSON string as well as a path, its keys MERGE with the
# project's settings files rather than replace them (a repo's permissions
# survive), and outputStyle resolves against .claude/output-styles in the launch
# directory. So one flag carries the whole activation for one session, and the
# repo keeps no record of it. Exported for tests: this payload IS the protocol's
# on-switch, so it is worth pinning down on its own.
export def gi-launch-settings [--hook]: nothing -> string {
    {outputStyle: $GI_STYLE}
    | if $hook { insert hooks {Stop: [{hooks: [{type: "command" command: $GI_COMMAND}]}]} } else { }
    | to json --raw
}

# Branches gi commits must never end a turn on. Why: gi history is internal
# working material — on a branch external users read, it would put them off.
# It reaches these branches only squash-merged, after finalization (see the
# git-intent-squash-archive skill).
const GI_PROTECTED_BRANCHES = ["main" "master"]

# Repo root (git top-level) of dir — default PWD — falling back to dir itself
# outside a repo. Both branches yield a physical (symlink-resolved) path — git
# canonicalizes --show-toplevel itself. Callers expand a user-given --root to
# match, so every path comparison downstream stays within one path family.
def gi-repo-root [dir?: path]: nothing -> path {
    let dir = $dir | default $env.PWD
    let top = do { ^git -C $dir rev-parse --show-toplevel } | complete
    if $top.exit_code == 0 { $top.stdout | str trim } else { $dir | path expand }
}

# Current branch at root, or null outside a repo / on detached HEAD — nothing
# to protect there, so the branch guard passes.
def gi-branch [root: path]: nothing -> any {
    let out = do { ^git -C $root branch --show-current } | complete
    let branch = $out.stdout | str trim
    if $out.exit_code == 0 and ($branch | is-not-empty) { $branch }
}

# Every path gi touches, in one record. No settings file among them: gi writes
# to none — activation travels with the launch (see gi-launch).
# - template_src: the gi working-doc seed; its destination is chosen per-enable
#   (see gi-enable), so only the src lives here.
# - style: the Canvas output style. Why distribute a local copy: this module is
#   vendored on its own, so it must carry the style itself rather than depend on
#   a Claude plugin being installed — `enable` drops it as a per-repo project
#   style. The srcs ship inside the module, so they vendor with it.
# - skills: the gi skills, seeded the same way. Why: project-level
#   .claude/skills needs no plugin install — file presence at session start IS
#   activation — and the style names git-intent-squash-archive, so seeding
#   makes that reference real in any gi-enabled repo.
def gi-paths [root: path]: nothing -> record {
    {
        template_src: $GI_HEADER_SRC
        style_src: ($GI_MODULE_DIR | path join "gi-md-src" "canvas-output-style.md")
        style_dst: ($root | path join ".claude" "output-styles" "canvas.md")
        skills_src: ($GI_MODULE_DIR | path join "gi-md-src" "skills")
        skills_dst: ($root | path join ".claude" "skills")
    }
}

# A canvas path in both forms: absolute (what GI_CANVAS carries and what the
# hook resolves against any cwd) and root-relative (what the user reads in a
# message). Shared by enable and the launcher so one rule serves both.
# Why expand the dirname and not the whole path: the canvas may not exist yet,
# and `path expand` resolves symlinks only for paths that do — this still lets
# an absolute path arriving through a symlink (cozy's ~/repos) come back
# root-relative.
def gi-doc-path [root: path, doc: path]: nothing -> record {
    let joined = $root | path join $doc
    let abs = $joined | path dirname | path expand | path join ($joined | path basename)
    {
        abs: $abs
        rel: (if ($abs | str starts-with $"($root)/") { $abs | path relative-to $root } else { $abs })
    }
}

# The bundled skills as [src dst] seed rows for enable's copy-if-absent loop.
# Enumerated from disk, not hardcoded: adding a skill under gi-md-src/skills
# is the whole change.
def gi-skill-seeds [paths: record]: nothing -> table {
    ls $paths.skills_src
    | get name
    | each {|dir|
        {
            src: ($dir | path join "SKILL.md")
            dst: ($paths.skills_dst | path join ($dir | path basename) "SKILL.md")
        }
    }
}

# The seeds `enable --force` may refresh: the style and the skills —
# distributed text the module owns. The working doc is deliberately absent:
# it holds the user's work and is never overwritten.
def gi-refresh-seeds [paths: record]: nothing -> table {
    [[src dst]; [$paths.style_src $paths.style_dst]]
    | append (gi-skill-seeds $paths)
}

# Seeded files whose content differs from the module source. Why content
# compare, not a version field: copy-if-absent pins a consumer repo to
# whatever was current at first enable, and nothing else ever signals drift.
# "Differs" covers a user edit too — the two are indistinguishable, and
# --force resolves both in the module's favor; that is what --force means.
def gi-stale [paths: record]: nothing -> list {
    gi-refresh-seeds $paths
    | where {|s| ($s.dst | path exists) and (open --raw $s.dst) != (open --raw $s.src) }
    | get dst
}

# The UUID of the session this command runs inside. Why the env var and not
# export-session's default (newest session file by mtime): during a live session
# the newest file is just as likely a subagent transcript or a session running in
# another window, and importing someone else's dialogue as your canvas is silent
# and wrong. Errors when unset — no fallback, since the wrong import is worse
# than none.
def gi-session-id []: nothing -> string {
    let sid = $env.CLAUDE_CODE_SESSION_ID? | default ""
    if ($sid | is-empty) {
        error make --unspanned {
            msg: "no live session: $env.CLAUDE_CODE_SESSION_ID is unset"
            help: "--from-session imports the session it runs inside — run it from a Claude Code session"
        }
    }
    $sid
}

# The working doc's starting content for --from-session: the canvas header, an
# import note, then the session's dialogue — user messages and Claude's visible
# replies; tool calls dropped, or kept as one-line placeholders with --tools.
# Why a note carrying the .jsonl path: everything left out is one `open` away,
# and the import can never contain the turn that asked for it (Claude Code
# writes the log as the turn runs), so the gap is stated in the file rather
# than only in the terminal, where it scrolls away. Exported for tests, which
# drive it with a fixture session.
export def gi-import-text [
    session_id: string # UUID, or a .jsonl path (what the tests pass)
    --tools # Keep tool calls as one-line placeholders instead of dropping them
]: nothing -> string {
    let file = resolve-session-file $session_id
    let left_out = if $tools { "Thinking is dropped here; tool calls are one-line placeholders" } else { "Tool calls, results, and thinking are dropped here" }
    let note = $"> Imported from the live session on (date now | format date '%Y-%m-%d %H:%M'). The turn that ran the import is missing — Claude Code writes the session log as the turn runs. ($left_out); the full record is `($file)`."
    # Replace the H1 rather than prepend the header: export-session titles the
    # doc from the session summary, and two H1s in a committed doc is noise.
    # First match only (no --all) — later `# ` lines belong to the dialogue.
    export-session --session $session_id --tools=$tools
    | get markdown
    | str replace --multiline --no-expand '^# .+' ([(open --raw $GI_HEADER_SRC) $note] | str join "\n")
}

# The 8-char session key used in the default doc name.
def gi-session-key [session_id: string]: nothing -> string {
    $session_id | str substring 0..7
}

# The gi actions, surfaced as tab completions on the positional below.
def "nu-complete gi-actions" []: nothing -> table {
    [
        [value description];
        [enable "seed this repo: the Canvas style, the gi skills, a working doc"]
        [open "launch a session on an unbound canvas (creating it if new) and record it there"]
        [resume "same, continuing the session the canvas records"]
        [status "show what is seeded here, and the canvas this session is bound to"]
        [check "hook body — reads the Stop event JSON on stdin"]
    ]
}

# gi — seed the gi protocol in this repo (`enable`), then open a session bound
# to a canvas (`open`/`resume`). One command, one positional action (tab-
# completes); with no action it reports status. Why one command, not six
# subcommands: they are verbs on the same object — a positional with a completer
# is the same call surface (`gi enable` still parses) with a single export.
# Named `main` because a module can't export a command named the same as the
# module — importing this file yields the `gi` command.
export def main [
    action?: string@"nu-complete gi-actions" # enable | open | resume | status | check (default: status)
    doc?: path # The canvas. enable: where to seed it (default gi/canvas-<timestamp>.md, or gi/session-<id>.md with --from-session); open: what to launch on, created from the template if new; resume: which canvas to continue
    --root: path # Repo root (default: git top-level); ignored by check
    --force # enable only: overwrite the seeded style and skills with the module's versions
    --from-session # enable only: start the working doc from this session's dialogue
    --commit # --from-session only: commit the imported doc
    --gitignore # --from-session only: keep the imported doc out of git
    --tools # --from-session only: keep tool calls in the import as one-line placeholders
    --no-hook # open/resume only: launch with the Canvas style but without the Stop-hook floor
]: any -> any {
    let event = $in # check reads the Stop event here; the others ignore it
    # Every action-bound option in one guard. Why a table: each option needs its
    # own span for the error label, and a copy of the same five-line `if` per
    # option buried the guards below that actually say something.
    let misplaced = [
        [given actions msg hint span];
        [$force ["enable"] "--force only makes sense with enable" "gi enable --force" (metadata $force).span]
        [$from_session ["enable"] "--from-session only makes sense with enable" "gi enable --from-session" (metadata $from_session).span]
        [$commit ["enable"] "--commit only makes sense with enable" "gi enable --from-session --commit" (metadata $commit).span]
        [$gitignore ["enable"] "--gitignore only makes sense with enable" "gi enable --from-session --gitignore" (metadata $gitignore).span]
        [$tools ["enable"] "--tools only makes sense with enable" "gi enable --from-session --tools" (metadata $tools).span]
        [$no_hook ["open" "resume"] "--no-hook only makes sense when opening a canvas" "gi open <doc> --no-hook" (metadata $no_hook).span]
    ]
    | where {|o| $o.given and ($action not-in $o.actions) }
    if ($misplaced | is-not-empty) {
        let bad = $misplaced | first
        error make {msg: $bad.msg label: {text: $"drop this, or use: ($bad.hint)" span: $bad.span}}
    }
    # The doc positional means a canvas for all three actions that take one —
    # where to seed it, or which one to launch on — and nothing anywhere else.
    # Only resume can't run without it: open mints a default, enable seeds one.
    if $doc != null and $action not-in ["enable" "open" "resume"] {
        error make {
            msg: "a canvas path only makes sense with enable, open, or resume"
            label: {text: "drop this, or use: gi enable <doc> / gi open <doc> / gi resume <doc>" span: (metadata $doc).span}
        }
    }
    if $action == "resume" and $doc == null {
        error make {
            msg: "gi resume needs a canvas file"
            label: {text: "name the canvas to continue: gi resume <doc>" span: (metadata $doc).span}
        }
    }
    if $commit and $gitignore {
        error make {
            msg: "--commit and --gitignore contradict each other"
            label: {text: "pick one: put the import in git, or keep it out" span: (metadata $gitignore).span}
        }
    }
    # These flags shape or file the imported transcript, so none of them means
    # anything without an import — committing whatever an older canvas happens
    # to hold is a different action, not this one.
    let import_only = [
        [given span];
        [$commit (metadata $commit).span]
        [$gitignore (metadata $gitignore).span]
        [$tools (metadata $tools).span]
    ]
    | where given
    if not $from_session and ($import_only | is-not-empty) {
        error make {
            msg: "--commit, --gitignore, and --tools apply to the imported doc"
            label: {text: "add --from-session to import this session" span: ($import_only | first | get span)}
        }
    }
    match $action {
        null | "status" => (gi-status --root $root)
        "enable" => (gi-enable --root $root --doc $doc --force=$force --from-session=$from_session --commit=$commit --gitignore=$gitignore --tools=$tools)
        "open" => (gi-launch --root $root --doc $doc --hook=(not $no_hook))
        "resume" => (gi-launch --root $root --doc $doc --continue --hook=(not $no_hook))
        "check" => ($event | gi-check)
        _ => {
            error make {
                msg: $"unknown gi action: ($action)"
                label: {text: "expected enable, open, resume, status, or check" span: (metadata $action).span}
            }
        }
    }
}

# Seed the gi protocol into this repo: the Canvas style, the gi skills, and a
# canvas. Turns nothing on — `gi open`/`gi resume` do that, per session — and
# writes to no settings file. Re-runnable: seeded files are never clobbered.
def gi-enable [
    --root: path # Repo root to seed (default: git top-level)
    --doc: path # Canvas path, relative to root (absolute also accepted)
    --force # Overwrite the seeded style and skills with the module's versions
    --from-session # Start the working doc from this session's dialogue
    --commit # Commit the imported doc
    --gitignore # Keep the imported doc out of git
    --tools # Keep tool calls in the import as one-line placeholders
]: nothing -> record {
    let root = $root | default (gi-repo-root) | path expand
    let paths = gi-paths $root
    let sid = if $from_session { gi-session-id }

    # Resolve the canvas: explicit arg wins; else an import gets its own
    # session-keyed name, so re-running it in one session refreshes one file and
    # leaves the repo's older canvases alone; else mint a timestamped one.
    # Why no "remember the last doc": nothing is recorded anywhere now — the
    # canvas is named by the path you pass to `gi open`/`gi resume`, and a repo
    # holds as many as you like.
    let doc = $doc
        | default (if $from_session { $"gi/session-(gi-session-key $sid).md" })
        | default $"gi/canvas-(date now | format date '%J_%Q').md"
    let paths_doc = gi-doc-path $root $doc
    let doc_abs = $paths_doc.abs
    let doc = $paths_doc.rel

    # Build the import before anything is written: a session that can't be read
    # must not leave a half-seeded repo behind.
    let imported = if $from_session {
        if ($doc_abs | path exists) {
            error make --unspanned {
                msg: $"working doc already exists: ($doc_abs)"
                help: "the import is the doc's starting content and won't overwrite work already in it — delete the file to re-import, or name another doc: gi enable <doc> --from-session"
            }
        }
        gi-import-text $sid --tools=$tools
    }

    # The import is the working doc's first content, so it lands before the seed
    # loop — whose copy-if-absent rule then skips the plain template.
    if $imported != null {
        mkdir ($doc_abs | path dirname)
        $imported | save --force $doc_abs
    }

    # Seed the working-doc template, the output style, and the gi skills. Why
    # not clobber: once they exist they are the user's files — refreshing would
    # destroy their edits. --force overwrites the style and skills — they are
    # distributed text a module update should be able to refresh — but never
    # the working doc, which holds the user's work.
    for seed in (
        [
            [src dst overwrite];
            [$paths.template_src $doc_abs false]
        ] | append (gi-refresh-seeds $paths | insert overwrite $force)
    ) {
        if $seed.overwrite or not ($seed.dst | path exists) {
            mkdir ($seed.dst | path dirname)
            cp $seed.src $seed.dst
        }
    }
    # An import lands in the working tree and stays there: neither flag by
    # default. Why not tracked: a transcript carries raw paths and whatever the
    # dialogue quoted, and that is the user's call to make once they have read
    # it. Why not ignored: gi runs on `git diff` and commit messages, so an
    # ignored canvas would keep every later turn out of git — the exact failure
    # gi exists to prevent.
    if $gitignore {
        # Beside the doc, not in the root .gitignore: gi owns that directory,
        # and the entry stays with the file it names wherever the doc lives.
        let ignore_file = $doc_abs | path dirname | path join ".gitignore"
        let entry = $doc_abs | path basename
        let lines = if ($ignore_file | path exists) { open --raw $ignore_file | lines } else { [] }
        if $entry not-in $lines {
            $lines | append $entry | append "" | str join "\n" | save --force $ignore_file
        }
    }
    if $commit {
        ^git -C $root add -- $doc_abs
        ^git -C $root commit --quiet -m $"gi: import session (gi-session-key $sid) as the working doc" -m "Dialogue up to the import; the full session log stays outside the repo." -- $doc_abs
    }

    # Seeding alone changes nothing about the session that ran it: the style and
    # the hook arrive with `gi open`/`gi resume`, so the next line is the whole
    # instruction. An imported canvas continues its own session, hence resume.
    let verb = if $from_session { "resume" } else { "open" }
    print $"gi seeded in ($root). Canvas: ($doc)"
    print $"open a bound session on it:  claude-nu gi ($verb) ($doc)"
    if $imported != null {
        # The log can never hold the turn that ran the import (Claude Code writes
        # it as the turn runs). After `gi resume` the agent is back in this same
        # session and still holds that turn, so it can close the gap itself —
        # the file's note can only state it.
        print $"the import stops before this turn — after resuming, ask the agent to append the tail from its context."
    }
    let status = gi-status --root $root
    # Surface drift at the moment the user is already touching gi — status
    # carries the same list, but nobody polls it.
    if not $force and ($status.stale | is-not-empty) {
        print $"note: ($status.stale | length) seeded file\(s\) differ from the module — `gi enable --force` refreshes them."
    }
    # `doc` and status's `canvas` are different questions: the canvas this call
    # seeded, versus the one the calling session is bound to (usually none).
    $status | insert doc $doc_abs
}

# The `session:` value from a canvas's YAML frontmatter, or null when the file
# has no frontmatter or no session key. Both origins write it: export-session
# for a canvas seeded with `gi enable --from-session`, and `gi open` for every
# other one. Null therefore means an unbound canvas — one `gi open` may claim.
# Exported for tests. Why parse by hand and not `open`: a .md file is raw text
# to nushell, and the frontmatter is between the first two `---` lines.
export def gi-frontmatter-session [file: path]: nothing -> any {
    let raw = open --raw $file
    if not ($raw | str starts-with "---") { return null }
    let block = $raw | lines | skip 1 | take until {|l| $l == "---" }
    let meta = try { $block | str join "\n" | from yaml } catch { {} }
    $meta.session?
}

# Write `session: <sid>` into a canvas's frontmatter, creating the block when
# the file has none. Why stamp the file rather than keep a side record: a
# `--from-session` canvas already carries this key, so both origins end up with
# one mechanism, and the binding travels with the file — move or copy a canvas
# and it still names its session. Exported for tests.
export def gi-stamp-session [file: path, sid: string]: nothing -> nothing {
    let raw = open --raw $file
    # First `---\n` only: inside an existing block the key joins it; with no
    # block, a new one is prepended. A canvas that already has `session:` never
    # reaches here — gi-launch refuses it (see the open branch).
    $raw
    | if ($raw | str starts-with "---\n") { str replace "---\n" $"---\nsession: ($sid)\n" } else { $"---\nsession: ($sid)\n---\n\n($in)" }
    | save --force $file
}

# The `claude` flags that bind a launch to a canvas's session. Split out of
# gi-launch because that command ends in an exec and can't be tested; this is
# the part worth pinning. --session-id mints the id up front (the canvas records
# it, so the canvas can be reopened); --resume returns to it. --name puts the
# canvas in the prompt box, the /resume picker, and the terminal title, so the
# session says which canvas it belongs to.
export def gi-launch-args [sid: string, doc: string, --continue]: nothing -> list<string> {
    if $continue { ["--resume" $sid] } else { ["--session-id" $sid] }
    | append ["--name" $doc]
}

# Launch Claude Code bound to one canvas — the only thing that turns gi on.
# Everything travels with the launch and nothing is left in the repo:
# `--settings` carries the Canvas style and (unless --no-hook) the Stop hook for
# this process only, and $env.GI_CANVAS names the canvas for the agent and for
# the hook, which inherits it as a child process.
# One canvas holds one session for life: open mints the session id itself
# (`--session-id`) and stamps it into the canvas's frontmatter, --continue reads
# it back and resumes. Why `--resume` and not `--fork-session`: the id must keep
# matching the frontmatter, or the canvas can't be reopened a third time.
def gi-launch [
    --doc: path # The canvas; created from the template when new (without --continue)
    --root: path # Repo root (default: git top-level)
    --continue # Continue the session recorded in the canvas frontmatter
    --hook # Carry the Stop-hook floor into the session
]: nothing -> nothing {
    let root = $root | default (gi-repo-root) | path expand
    let doc = $doc | default $"gi/canvas-(date now | format date '%J_%Q').md"
    let doc_abs = (gi-doc-path $root $doc).abs
    let doc_rel = (gi-doc-path $root $doc).rel
    let style = (gi-paths $root).style_dst
    # outputStyle names a style file that must already be on disk here; without
    # it Claude Code would launch with no style and gi would be silently half on.
    if not ($style | path exists) {
        error make --unspanned {
            msg: $"the Canvas style is not seeded in this repo: ($style)"
            help: "run `claude-nu gi enable` first"
        }
    }
    # The canvas exists before a session is bound to it: open stamps the id it
    # mints into the frontmatter, and there must be a file to stamp.
    if not $continue and not ($doc_abs | path exists) {
        mkdir ($doc_abs | path dirname)
        cp $GI_HEADER_SRC $doc_abs
    }
    let sid = if $continue {
        if not ($doc_abs | path exists) {
            error make --unspanned {msg: $"no such canvas: ($doc_abs)" help: "check the path, or start one: claude-nu gi open <doc>"}
        }
        let sid = gi-frontmatter-session $doc_abs
        if ($sid | is-empty) {
            error make --unspanned {
                msg: $"($doc_abs) has no `session:` in its frontmatter — nothing to resume"
                help: "an unbound canvas gets its session on the first `claude-nu gi open <doc>`; run that instead"
            }
        }
        $sid
    } else {
        # One canvas, one session, for life. `claude --session-id` rejects an id
        # already on disk ("Session ID … is already in use"), so opening a bound
        # canvas would fail in the CLI anyway — say it here, where the fix is a
        # word away, instead of letting a raw CLI error land on the user.
        let bound = gi-frontmatter-session $doc_abs
        if ($bound | is-not-empty) {
            error make --unspanned {
                msg: $"($doc_abs) is already bound to session (gi-session-key $bound)"
                help: "reopen it with `claude-nu gi resume <doc>`; gi open only takes a canvas that has no session yet"
            }
        }
        let sid = random uuid
        gi-stamp-session $doc_abs $sid
        $sid
    }
    # Same guard the hook enforces, surfaced before the session starts — a
    # branch switch now beats being blocked mid-session with commits already made.
    let branch = gi-branch $root
    if $hook and ($branch in $GI_PROTECTED_BRANCHES) {
        print $"note: this repo is on ($branch) — gi commits belong on a work branch; the Stop hook will block turns until you switch."
    }
    let args = gi-launch-args $sid $doc_rel --continue=$continue
    print $"canvas ($doc_rel), session (gi-session-key $sid)(if $hook { '' } else { ', no Stop hook' })"
    # cd so claude resolves the session under this project and so outputStyle
    # finds .claude/output-styles here.
    do {
        cd $root
        with-env { GI_CANVAS: $doc_abs } { ^claude --settings (gi-launch-settings --hook=$hook) ...$args }
    }
}

# What gi has seeded in this repo, plus whether the session asking is bound to a
# canvas. Pipeline-friendly record.
def gi-status [
    --root: path # Repo root to inspect (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-repo-root) | path expand
    let paths = gi-paths $root
    # Paths stay absolute. Shortening them against PWD made the same field
    # change spelling with where you stand. Data here; display is the caller's
    # business.
    {
        # Read from the environment, not from a file: activation is per session,
        # so "is gi on" is a property of who is asking, not of the repo.
        canvas: ($env.GI_CANVAS?)
        style: $paths.style_dst
        skills: (gi-skill-seeds $paths | get dst)
        stale: (gi-stale $paths)
    }
}

# Stop-hook body. Reads the event JSON on stdin and returns either nothing
# (allow the turn to end) or the block-decision JSON string. `nu -c` renders
# the return value to stdout, which is the Stop hook's control channel; the
# command always exits 0, per the contract. Returning (not printing) keeps it
# unit-testable. The single `to json` lives here, next to the contract it
# serves — the rules deal in records only. Also accepts nothing: run by hand
# with no stdin, the normalization below treats it as an empty event.
def gi-check []: [string -> any, nothing -> any] {
    let payload = try { $in | default "" | from json } catch { {} }
    # Valid JSON need not be an object ("hi", 123, null, [1]) — normalize to a
    # record: anything else would throw in the guard below or entering the
    # rules, above/outside the contract boundary.
    let payload = if ($payload | describe | str starts-with "record") { $payload } else { {} }
    # Already continuing from a prior block — let it end to avoid a loop.
    if ($payload.stop_hook_active? | default false) { return }

    # Contract boundary: an internal error (hand-broken settings file, git not
    # on PATH, a typo in GI_HOOK_MAX_LEN) must not become a non-zero exit —
    # Claude Code treats that as a non-blocking error and enforcement silently
    # vanishes. Convert it to a block whose reason carries the error: loud,
    # in front of the agent, and the loop guard above still lets the turn end
    # on the retry. Not a fail-fast violation — this IS the failure surface.
    let decision = try { $payload | gi-check-rules } catch {|err|
        {decision: "block" reason: $"gi check failed internally — fix this before continuing: ($err.msg)"}
    }
    if $decision != null { $decision | to json --raw }
}

# The actual gi rules, free to throw; gi-check owns the exit-0 contract.
def gi-check-rules []: record -> any {
    let payload = $in
    # $env.GI_CANVAS is the activation itself: `gi open`/`gi resume` set it on
    # the session they launch, and the hook inherits it as a child process. It is
    # also the only thing that makes a block actionable — the reason has to name
    # the canvas to move the answer into. Unset, there is no canvas, no gi
    # session, and nothing to enforce; the turn ends. No second source to consult.
    let canvas = $env.GI_CANVAS? | default ""
    if ($canvas | is-empty) { return }

    let root = gi-repo-root ($payload.cwd? | default $env.PWD)

    # Branch guard, before the message rule: even a perfect `done` may not end
    # a turn on a protected branch — gi commits are internal working history,
    # and the sooner the agent hears it, the fewer commits there are to move.
    let branch = gi-branch $root
    if $branch in $GI_PROTECTED_BRANCHES {
        let reason = $"You are on `($branch)` — gi commits are internal working history and must not land here. Switch to a work branch \(`git switch -c <topic>`, moving any commits already made); it gets squash-merged into `($branch)` after finalization."
        return {decision: "block" reason: $reason}
    }

    let message = $payload.last_assistant_message? | default ""
    if (gi-allowed $message) { return }

    # Name the canvas the short way when it is inside this repo — the agent
    # reads this path in a message, and the absolute form is noise there.
    let doc = if ($canvas | str starts-with $"($root)/") { $canvas | path relative-to $root } else { $canvas }
    # The escape hatch is safe by construction: the blocked message is already
    # on the user's screen, and the stop_hook_active guard ends the turn on the
    # follow-up whatever it says — a misfire can redirect one reply, never trap
    # the agent.
    let reason = $"Chat may carry only `done`/`noted` or a short pointer \(one line with a path/link). Move the full answer into `($doc)` and commit it; leave only a pointer in chat. If this block looks like a misfire — wrong canvas, no gi work in this session — don't move anything: reply with one short line telling the user to read your previous message above in the chat and to check the session's canvas \(`claude-nu gi status`)."
    {decision: "block" reason: $reason}
}

# The allow-rule: what may stand alone in chat. True (allowed) when, after trim:
# empty; or `done`/`noted` (trailing punctuation ok); or a short pointer — one
# line, within the length budget, carrying a link signal (backtick, `→`, or a
# filename). Everything else (prose, long unanchored lines) is blocked.
# Why a budget env-var: "short pointer" is fuzzy; GI_HOOK_MAX_LEN makes the
# threshold tunable without editing the hook (legacy prefix kept — deployed
# sessions already use it). Default is strict — prose fails.
export def gi-allowed [message: string]: nothing -> bool {
    let text = $message | str trim
    if ($text | is-empty) { return true }
    if (($text | str lowercase | str replace -r '[.!…]+$' '') in ["done" "noted"]) { return true }

    let max = $env.GI_HOOK_MAX_LEN? | default 480 | into int
    let single_line = not ($text | str contains "\n")
    let within = ($text | str length) <= $max
    # The filename signal needs a 2+ char lowercase/digit extension: `\w+`
    # also matched abbreviations (`e.g`) and glued sentences (`end.Next`),
    # letting short prose through as a "pointer". Real one-letter-extension
    # files (main.c) are indistinguishable from abbreviations; a pointer to
    # one still passes via backticks.
    let has_signal = ($text =~ '`') or ($text =~ '→') or ($text =~ '[\w./-]+\.[a-z0-9]{2,}')
    $single_line and $within and $has_signal
}
