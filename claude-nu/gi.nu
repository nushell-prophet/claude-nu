# gi — the gi protocol: seeded per repo, activated per session at launch.
#
# The gi protocol moves all "what/why" into git: the diff and the commit body
# carry the record, the chat carries almost nothing. Three commands do the work,
# and the split between them is the whole design:
#
#   gi enable          seeds files into the repo — the Canvas output style and
#                      the gi skills. Writes nothing to settings, turns nothing
#                      on, and makes no canvas: that is the launcher's job, so
#                      no two verbs ever write the same canvas. `gi open` seeds
#                      the same files itself, so this verb is not a prerequisite
#                      for it; what it still owns is `--force` (refresh after a
#                      module update — `open` must never clobber an edited
#                      style) and the chicken-and-egg of `gi import`, which
#                      needs the `gi-canvas` skill in the repo but launches
#                      nothing and so never passes through `open`.
#   gi import          writes one canvas, from a session's dialogue — the one it
#                      runs inside, or any session named on the line. The only
#                      verb that can capture the session running it, since it
#                      launches nothing: `enable` seeds no canvas, and `open`
#                      cannot be reached from the session being imported.
#   gi open            launches Claude Code bound to one canvas: `--settings`
#                      carries the output style and the Stop hook for that launch
#                      alone, `--append-system-prompt` names the canvas to the
#                      agent, and $env.GI_CANVAS names it to the hook, which runs
#                      as a child of that session. A canvas holds
#                      one session for life — a canvas with no session gets one
#                      minted and written in, one that has it is resumed. Which
#                      case it is, the file says; there is no second verb.
#                      `--new-session` is the way out when that session is gone
#                      (deleted, expired): it overwrites the recorded id.
#                      `--fork` is the other direction — keep the canvas bound
#                      as it is and open a copy of it (`plan.md` -> `plan_1.md`)
#                      on a session of its own, so a document planned in one
#                      conversation can be carried on in a fresh context while
#                      the conversation that planned it stays readable.
#
# Bare `gi` is the third name and does no work: it reports what is seeded here
# and which canvas the asking session is bound to.
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
# blocks the turn when the final chat message is more than one short line, and
# blocks turns ending on main/master (gi commits are internal
# working history — they reach a public branch only squash-merged, after
# finalization). It comes with every `gi open`; `--no-hook` opens a canvas with
# the style alone.
#
# There is no `gi disable` and no migration path: gi writes to no settings file,
# so there is nothing to switch off. A repo set up by the older, repo-wide gi
# keeps working from its own settings until those keys are deleted by hand.

use sessions.nu [export-session resolve-session-file read-session-records user-message-texts "nu-complete claude sessions"]

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

# The canvas seed. A const of its own because two callers need it: gi-launch
# copies it when opening a canvas that does not exist yet, and gi-import-text
# puts it at the head of an imported dialogue.
const GI_HEADER_SRC = ($GI_MODULE_DIR | path join "gi-md-src" "canvas-header.md")

# The shell command Claude Code runs for the Stop event. `--stdin` feeds the
# event JSON to the script as `$in`. The absolute path is required — relative
# paths are not resolved at hook time — and quoted, for a module dir with a
# space in it.
# Why a script and not `-c 'use ...; $in | gi check'`: the hook body then lives
# in a checked file (see gi-hook.nu) rather than in a string literal nesting
# quotes through JSON and a shell. Why gi-hook.nu imports gi.nu rather than the
# `claude-nu` umbrella: `gi check` is the hook's body, not a verb anyone types,
# so mod.nu does not re-export it and `claude-nu gi <TAB>` stays the verbs a
# user has a reason to run.
const GI_COMMAND = $"nu --stdin \"($GI_MODULE_DIR | path join 'gi-hook.nu')\""

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

# Every path enable seeds, in one record. No settings file among them: gi writes
# to none — activation travels with the launch (see gi-launch). No canvas among
# them either: `gi open` creates that, from $GI_HEADER_SRC.
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
        style_src: ($GI_MODULE_DIR | path join "gi-md-src" "canvas-output-style.md")
        style_dst: ($root | path join ".claude" "output-styles" "canvas.md")
        skills_src: ($GI_MODULE_DIR | path join "gi-md-src" "skills")
        skills_dst: ($root | path join ".claude" "skills")
        ignore_dst: ($root | path join ".claude" ".gitignore")
    }
}

# The directory gi runs in: --root when the user names one, otherwise where
# they are standing. Everything a gi command does happens here — the launch
# cd's to it, a relative canvas is read against it, and the short form printed
# and handed to the agent is relative to it.
# `root` (the repo) is a different question and stays a different value: it is
# where `.claude/` is seeded and which branch the guard reads. Those are
# repo-scoped; the canvas is not.
# Why not the repo root for both, which is what this replaced: a path typed on a
# command line means what it means everywhere else in a shell — relative to
# where you stand — and inside a monorepo the repo root is never where you work.
# Run from `mono/sub`, `gi open todo/x.md` silently made and bound
# `mono/todo/x.md`, a second file with the same basename as the one the user
# meant, and the session wrote its whole answer into it.
def gi-run-dir [root?: path]: nothing -> path {
    $root | default $env.PWD | path expand
}

# A canvas path in both forms: absolute (what GI_CANVAS carries and what the
# hook resolves against any cwd) and relative to the run directory (what the
# user reads in a message, pastes back as a command, and what the agent — whose
# cwd is that directory — resolves). Shared by import and the launcher so one
# rule serves both.
# Why expand the dirname and not the whole path: the canvas may not exist yet,
# and `path expand` resolves symlinks only for paths that do — this still lets
# an absolute path arriving through a symlink (cozy's ~/repos) come back
# relative.
def gi-doc-path [dir: path, doc: path]: nothing -> record {
    let joined = $dir | path join $doc
    let abs = $joined | path dirname | path expand | path join ($joined | path basename)
    {
        abs: $abs
        rel: (if ($abs | str starts-with $"($dir)/") { $abs | path relative-to $dir } else { $abs })
    }
}

# A path as the caller would type it from where they stand: relative to the
# current directory when it sits under it, absolute when it does not.
# The convention nu-multiproof and nu-cybergraph already follow (`_fs.nu
# cwd-relative`), duplicated here rather than cross-imported, as those copies
# are. For a path gi constructs and hands back for a person to read; a caller
# who needs a handle rather than a label takes `| path expand` — the exact
# inverse, since the value is relative to the cwd it was made in.
# Why a prefix test and not `try { path relative-to } catch { }`: "not under
# here" is an ordinary answer, not a failure. The trailing separator is part
# of the prefix: without it `/a/bc` counts as under `/a/b`.
def cwd-relative []: path -> path {
    let p = $in
    if ($p | str starts-with ($env.PWD | path join "")) {
        $p | path relative-to $env.PWD
    } else {
        $p
    }
}

# Copy one file, byte for byte. Every copy gi makes goes through here.
# Not `cp`, because: nushell's builtin (0.115.0) mixes concurrent copies up —
# two `cp` calls running in different threads write each other's bytes, so a
# destination ends up the right length holding another file's content, and
# nothing errors. Measured: 46 of 205 copies corrupted under `par-each`, 0 with
# this, 0 with an external `cp`. That is what made `tests/test_gi.nu` fail a
# different test on nearly every run — nutest runs tests in parallel, so several
# `gi enable` seedings copy at once. It is not only a test problem: `gi open`
# seeds and then launches `claude` against those very files.
# --force because `gi enable --force` refreshes seeds that are already there;
# the other two callers write a path they have just shown to be free.
def copy-file [src: path, dst: path]: nothing -> nothing {
    open --raw $src | save --raw --force $dst
}

# The canvas name minted when the user names none. A def and not a const: the
# timestamp has to be read when the command runs, not when the module parses.
def gi-default-doc []: nothing -> string {
    $"gi/canvas-(date now | format date '%J_%Q').md"
}

# The next name in a fork series: `plan.md` -> `plan_1.md`, and a fork of
# `plan_1.md` -> `plan_2.md`. The trailing `_n` is stripped before numbering, so
# forks of forks stay flat siblings instead of nesting into `plan_1_1.md` —
# every canvas grown from one document sorts next to it.
# Not the first free gap because: a fork name gets written down outside the
# repo — a chat pointer, a commit body — and gi/ is untracked by default, so
# nothing would stop a deleted `plan_1.md` from being handed to a different
# canvas later. Exported for tests.
export def gi-fork-name [name: string, siblings: list<string>]: nothing -> string {
    let parsed = $name | path parse
    let stem = $parsed.stem | str replace --regex '_\d+$' ''
    let taken = $siblings
        | each {|s| $s | path parse }
        | where extension == $parsed.extension
        | get stem
        | parse --regex '^(?<base>.+)_(?<n>\d+)$'
        | where base == $stem
        | get n
        | into int
    $parsed | update stem $"($stem)_(($taken | append 0 | math max) + 1)" | path join
}

# Copy a canvas to the next free name in its series and hand back the copy.
# Why the copy is what the launch then opens: the session binding travels with
# the file (see gi-stamp-session), so a plain `cp` leaves two canvases naming
# one session and both `gi open`s land in the same conversation. Forking is the
# spelling for the other case — same document, deliberately another session
# (a fresh context to implement what the first one planned).
# Exported for tests.
export def gi-fork-canvas [src: path]: nothing -> path {
    if not ($src | path exists) {
        error make --unspanned {
            msg: $"no canvas to fork: ($src)"
            help: "--fork copies a canvas that exists; drop it to start a new one"
        }
    }
    # The copy is stamped with a fresh id as soon as the launch continues, and a
    # canvas whose frontmatter is unclosed cannot be stamped. Ask that of the
    # source here, before writing: the same error raised after the copy leaves
    # an orphan canvas bound to the source's session, burns a name out of the
    # `_n` series (numbering is max+1, so the gap is never reused), and names a
    # path the user never typed.
    gi-frontmatter-split $src | ignore
    let dir = $src | path dirname
    let dst = $dir | path join (gi-fork-name ($src | path basename) (ls $dir | get name | path basename))
    copy-file $src $dst
    $dst
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

# Copy the seeds into the repo, never clobbering a file that is already there
# unless --force says to: once seeded they are the user's files, and refreshing
# would destroy their edits. --force overwrites, because they are distributed
# text a module update should be able to refresh.
# Shared by `gi enable` and `gi open`. Why `open` seeds instead of refusing: the
# style has to be on disk for `--settings` to name it, and refusing was its only
# move — an error that also sat *after* the fork copy, so a launch that would not
# start still left a stray canvas behind and burned a name in the `_n` series.
# Seeding removes the error rather than reordering around it.
def gi-seed [paths: record, --force, --no-gitignore]: nothing -> nothing {
    for seed in (gi-refresh-seeds $paths | insert overwrite $force) {
        if $seed.overwrite or not ($seed.dst | path exists) {
            mkdir ($seed.dst | path dirname)
            copy-file $seed.src $seed.dst
        }
    }
    if not $no_gitignore {
        let existing = if ($paths.ignore_dst | path exists) { open --raw $paths.ignore_dst } else { "" }
        gi-ignore-text $paths $existing | save --force $paths.ignore_dst
    }
}

# The block markers gi owns inside `.claude/.gitignore`. Everything between them
# is regenerated; everything outside is somebody else's and is carried through
# untouched — the same rule the seeded style and skills get, and the same rule
# `gi import --gitignore` follows for the file beside a canvas. `.claude/` is a
# shared folder: gi seeds into it but does not own it.
const GI_IGNORE_BEGIN = "# gi seeds — regenerated by `claude-nu gi`. `git add` them to track them instead; ignore rules do not apply to tracked files."
const GI_IGNORE_END = "# end gi seeds"

# The ignore file gi writes beside its seeds, so a repo it seeded does not show
# six untracked files nobody wants to read in a diff. `existing` is the file's
# current content ("" when there is none); gi's block replaces the old one in
# place, or is appended when the file has none yet.
# Exact paths, never `*` or a bare `skills/`: a directory pattern would silently
# hide a skill the user wrote by hand.
# The block does not list the ignore file itself, on purpose. `git status` then
# still reports `?? .claude/` as a single line resolving to this file alone, so
# the folder says gi wrote here while the seeds stay quiet; hiding it too makes
# `.claude/` vanish from `git status`, which is how you forget a tool is writing
# into your repo. Regenerated on every seed run from the same enumeration the
# copy loop uses, so a skill added to gi-md-src can never be left unignored.
def gi-ignore-text [paths: record, existing: string = ""]: nothing -> string {
    let dir = $paths.ignore_dst | path dirname
    let lines = $existing | lines
    let before = $lines | take until {|l| $l == $GI_IGNORE_BEGIN }
    # A block opened and never closed means the file was hand-edited into a
    # shape gi cannot rewrite without guessing where its own lines end. Say so
    # rather than append a second block or swallow the rest of the file.
    if (($before | length) < ($lines | length)) and ($GI_IGNORE_END not-in $lines) {
        error make --unspanned {
            msg: $"gi's block in ($paths.ignore_dst) has no closing line"
            help: $"add `($GI_IGNORE_END)` after gi's entries, or delete the block and let gi write a new one"
        }
    }
    let after = $lines | skip until {|l| $l == $GI_IGNORE_END } | skip 1
    $before
    | append $GI_IGNORE_BEGIN
    | append (gi-refresh-seeds $paths | get dst | each {|dst| $dst | path relative-to $dir })
    | append $GI_IGNORE_END
    | append $after
    | append ""
    | str join "\n"
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

# The drift note, printed by every verb the user reaches gi through: `enable`,
# `import`, and each `gi open` launch. Why all three and not just status, which
# already carries the list: copy-if-absent pins a repo to whatever the module
# held at its first seed, nobody polls status, and a repo can then run months of
# canvas sessions on a style the module has since rewritten — this change is how
# the seed of a rewritten rule reaches a repo that was seeded before it.
# A note, never an error: the seeded copy still works, and the difference may be
# the user's own edit to it, which --force would discard.
def gi-stale-note [paths: record]: nothing -> nothing {
    let stale = gi-stale $paths
    if ($stale | is-not-empty) {
        print $"note: ($stale | length) seeded file\(s\) differ from the module — `gi enable --force` refreshes them:"
        for f in $stale { print $"  ($f | cwd-relative)" }
    }
}

# The UUID of the session this command runs inside — what `gi import` falls back
# to when no session is named. Why the env var and not export-session's default
# (newest session file by mtime): during a live session the newest file is just
# as likely a subagent transcript or a session running in another window, and
# importing someone else's dialogue as your canvas is silent and wrong. Errors
# when unset — no fallback, since the wrong import is worse than none.
def gi-session-id []: nothing -> string {
    let sid = $env.CLAUDE_CODE_SESSION_ID? | default ""
    if ($sid | is-empty) {
        error make --unspanned {
            msg: "no live session: $env.CLAUDE_CODE_SESSION_ID is unset"
            help: "with no session named, `gi import` imports the session it runs inside — name one, or run it from a Claude Code session"
        }
    }
    $sid
}

# A canvas's starting content for `gi import`: the canvas header, an
# import note, then the session's dialogue — user messages and Claude's visible
# replies; tool calls dropped, or kept as one-line placeholders with --tools.
# Why a note carrying the .jsonl path: everything left out is one `open` away,
# so the gap is stated in the file rather than only in the terminal, where it
# scrolls away. Why --live is a parameter and not "compare against
# $env.CLAUDE_CODE_SESSION_ID": only the caller knows whether the session was
# named or fell back to the live one, and the missing-tail sentence is true in
# exactly that second case — a named older session's log is complete. Exported
# for tests, which drive it with a fixture session.
export def gi-import-text [
    session_id: string # UUID, or a .jsonl path (what the tests pass)
    --tools # Keep tool calls as one-line placeholders instead of dropping them
    --live # This is the session running the import: its log cannot hold the current turn
]: nothing -> string {
    let file = resolve-session-file $session_id
    let left_out = if $tools { "Thinking is dropped here; tool calls are one-line placeholders" } else { "Tool calls, results, and thinking are dropped here" }
    let source = if $live {
        "Imported from the live session"
    } else {
        $"Imported from session (gi-session-key $file)"
    }
    let gap = if $live { " The turn that ran the import is missing — Claude Code writes the session log as the turn runs." }
    let note = $"> ($source) on (date now | format date '%Y-%m-%d %H:%M').($gap | default '') ($left_out); the full record is `($file)`."
    # Replace the H1 rather than prepend the header: export-session titles the
    # doc from the session summary, and two H1s in a committed doc is noise.
    # First match only (no --all) — later `# ` lines belong to the dialogue.
    {path: $file} | export-session --tools=$tools
    | str replace --multiline --no-expand '^# .+' ([(open --raw $GI_HEADER_SRC) $note] | str join "\n")
}

# The 8-char session key used in the default doc name and in messages. Takes a
# UUID or a .jsonl path, because `gi import` accepts both: `path basename`
# leaves a bare UUID untouched, so one line serves the two spellings.
def gi-session-key [session: string]: nothing -> string {
    $session | path basename | str replace --regex '\.jsonl$' '' | str substring 0..7
}

# Why real subcommands and not one command with an action positional (which is
# what this replaced): the action was a string, so the parser could not tell
# `--force` from `--no-hook` and every option had to be matched against the
# action by hand — six run-time guards that a signature states for free. And
# `help claude-nu gi` showed every flag at once, including the ones meaningless
# for the verb being typed. Each verb now carries its own signature and help.
# `main` is the name a module gives its own command, so importing this file
# yields `gi`, and `gi <verb>` for the rest.
#
# Everything below this line up to the def is the command's own help text —
# nushell shows the contiguous comment block, so keep the rationale above the
# blank line.

# What gi has seeded in this repo, and the canvas this session is bound to.
# The verbs: `gi enable`, `gi import`, `gi open`.
export def main [
    --root: path # Repo root to inspect (default: git top-level)
]: nothing -> record {
    gi-status --root $root
}

# Open a canvas: launch a session bound to it, creating the canvas from the
# template when it does not exist and continuing the session it already records
# when it has one.
export def --wrapped "gi open" [
    doc?: path # The canvas, relative to where you are (default: gi/canvas-<timestamp>.md); with --fork, the canvas to fork FROM
    --root: path # Run gi in this directory instead of here: the canvas is read there and the session starts there (default: your cwd)
    --no-hook # Launch with the Canvas style but without the Stop-hook floor
    --new-session # Start a fresh session on this canvas, overwriting the id it records
    --fork # Copy the named canvas to its next `_n` sibling and open that, on a session of its own
    --dangerously-skip-permissions # Pass claude's flag of the same name through
    ...rest: string # Any other flags go straight to `claude`
]: nothing -> nothing {
    # --fork is the one case where the positional names a source rather than the
    # file being opened, so there is nothing to copy when it is omitted.
    if $fork and ($doc | is-empty) {
        error make --unspanned {
            msg: "--fork needs the canvas to fork from"
            help: "claude-nu gi open gi/plan.md --fork"
        }
    }
    # Both mint an id, but on different files: --new-session overwrites the one
    # this canvas records, --fork leaves it alone and binds the copy. Together
    # they name two intentions at once, and the flags cannot say which file the
    # user meant to keep.
    if $fork and $new_session {
        error make --unspanned {
            msg: "--fork and --new-session cannot be combined"
            help: "--fork already opens its copy on a fresh session; --new-session restarts the named canvas in place"
        }
    }
    # Why --dangerously-skip-permissions is declared when --wrapped would forward
    # it anyway: under --wrapped an unknown flag typed BEFORE the doc is taken as
    # the doc (`gi open --dangerously-skip-permissions` would name a canvas that),
    # and this is the flag most often typed with no canvas named. Declared, it
    # parses in either position. It is also the one pass-through worth showing in
    # `help gi open`.
    let extra = if $dangerously_skip_permissions { ["--dangerously-skip-permissions"] } else { [] }
    | append $rest
    # The other half of the same parsing rule: an undeclared flag typed before
    # the doc lands in the doc. A canvas path never starts with a dash, so say
    # so here — otherwise a typo silently creates a canvas named `--modle`, and
    # the pass-through rule below never sees the flag it was meant to catch.
    if ($doc | default "" | str starts-with "-") {
        error make {
            msg: $"($doc) is not a canvas path"
            label: {text: "flags for `claude` go after the canvas: gi open <doc> <flags>" span: (metadata $doc).span}
        }
    }
    gi-launch --root $root --doc $doc --hook=(not $no_hook) --new-session=$new_session --fork=$fork --extra $extra
}

# Seed the gi protocol into this repo: the Canvas style and the gi skills.
# Turns nothing on — `gi open` does that, per session — and writes to
# no settings file. Re-runnable: seeded files are never clobbered.
# Not a prerequisite for `gi open`, which seeds the same files itself. Run it to
# refresh seeds with --force, or to get the `gi-canvas` skill into a repo where
# the work will start from inside a live session rather than from a launch.
export def "gi enable" [
    --root: path # Repo root to seed (default: git top-level)
    --force # Overwrite the seeded style and skills with the module's versions
    --no-gitignore # Do not write .claude/.gitignore — leave the seeds visible to git
]: nothing -> record {
    let root = $root | default (gi-repo-root) | path expand
    let paths = gi-paths $root
    # Why only this verb can decline the ignore file, while `gi open` always
    # writes it: `open` is where a repo that never ran `enable` gets seeded, and
    # that repo would otherwise get the noise back. Declining is the deliberate
    # act, so it belongs on the deliberate verb — and it is a one-time state
    # anyway: `git add` the seeds and the ignore file stops applying to them.
    gi-seed $paths --force=$force --no-gitignore=$no_gitignore
    # Seeding alone changes nothing about the session that ran it: the style and
    # the hook arrive with `gi open`, so the next lines are the whole
    # instruction. Seeding writes no canvas, so both verbs that make one are
    # named here — this is where the user is standing.
    # cwd-relative cannot shorten the root itself (a directory is not *under*
    # itself), and the common call runs exactly there — so that case is named
    # in words instead of echoing the long absolute path back.
    print (if $root == ($env.PWD | path expand) {
        "gi seeded here."
    } else {
        $"gi seeded in ($root | cwd-relative)."
    })
    print $"start a canvas:  claude-nu gi open [<doc>]"
    print $"...or from a session's dialogue:  claude-nu gi import [<session>]"
    # Surface drift at the moment the user is already touching gi — status
    # carries the same list, but nobody polls it. --force just refreshed them,
    # so there is nothing left to report.
    if not $force { gi-stale-note $paths }
    gi-status --root $root
}

# Why a verb of its own and not a flag on `gi enable` (which is what this
# replaced): enable seeds distributed text and makes no canvas, so an import
# living there dragged in a path and three flags the command had no other use
# for, plus three run-time guards to keep them apart. Why the session is a
# parameter and not "the session I run inside": a switch can only ever mean the
# live one, so importing an older chat from the REPL was impossible, and a
# switch gives a completer nothing to complete.

# Write a canvas from a session's dialogue: the canvas header, an import note,
# then the user's messages and Claude's visible replies. The doc records that
# session, so `gi open <doc>` resumes it instead of minting a new one.
export def "gi import" [
    session?: string@"nu-complete claude sessions" # Session UUID or .jsonl path (default: the session this runs inside)
    --to: path # Where the canvas lands, relative to where you are (default: gi/session-<key>.md)
    --root: path # Run gi in this directory instead of here: --to is read there (default: your cwd)
    --tools # Keep tool calls as one-line placeholders instead of dropping them
    --commit # Commit the imported doc
    --gitignore # Keep the imported doc out of git
]: nothing -> record {
    if $commit and $gitignore {
        error make {
            msg: "--commit and --gitignore contradict each other"
            label: {text: "pick one: put the import in git, or keep it out" span: (metadata $gitignore).span}
        }
    }
    # Not `| default (gi-session-id)`: default evaluates its argument eagerly,
    # so the live-session lookup would error even when a session was named.
    let sid = if $session == null { gi-session-id } else { $session }
    # Read the run directory off the flag before the next line shadows it.
    let dir = gi-run-dir $root
    let root = $root | default (gi-repo-root) | path expand
    let paths = gi-paths $root
    # Default is session-keyed, so re-running it for one session names one file
    # and leaves the repo's other canvases alone.
    # Why --to and not a second positional: the common in-session call names a
    # path but no session, and a positional cannot be skipped.
    let paths_doc = gi-doc-path $dir ($to | default $"gi/session-(gi-session-key $sid).md")
    # Check before reading the session: a doc that already holds work must not
    # be reported as a near-miss after a long export.
    if ($paths_doc.abs | path exists) {
        error make --unspanned {
            msg: $"canvas already exists: ($paths_doc.abs)"
            help: "the import is the doc's starting content and won't overwrite work already in it — delete the file to re-import, or name another doc: gi import --to <doc>"
        }
    }
    # Build the import before anything is written: a session that can't be read
    # must leave no half-written canvas behind.
    let imported = gi-import-text $sid --tools=$tools --live=($session == null)
    mkdir ($paths_doc.abs | path dirname)
    $imported | save --force $paths_doc.abs

    # An import lands in the working tree and stays there: neither flag by
    # default. Why not tracked: a transcript carries raw paths and whatever the
    # dialogue quoted, and that is the user's call to make once they have read
    # it. Why not ignored: gi runs on `git diff` and commit messages, so an
    # ignored canvas would keep every later turn out of git — the exact failure
    # gi exists to prevent.
    if $gitignore {
        # Beside the doc, not in the root .gitignore: gi owns that directory,
        # and the entry stays with the file it names wherever the doc lives.
        let ignore_file = $paths_doc.abs | path dirname | path join ".gitignore"
        let entry = $paths_doc.abs | path basename
        let lines = if ($ignore_file | path exists) { open --raw $ignore_file | lines } else { [] }
        if $entry not-in $lines {
            $lines | append $entry | append "" | str join "\n" | save --force $ignore_file
        }
    }
    if $commit {
        ^git -C $root add -- $paths_doc.abs
        ^git -C $root commit --quiet -m $"gi: import session (gi-session-key $sid) as the working doc" -m "Dialogue up to the import; the full session log stays outside the repo." -- $paths_doc.abs
    }

    print $"canvas: ($paths_doc.rel)"
    # Not a blocked next step — `gi open` seeds the style itself. It is the
    # skills that only `enable` puts here, and an in-session `gi import` needs
    # them. Say so while the user is still looking at the command.
    if not ($paths.style_dst | path exists) {
        print $"the gi skills are not in this repo yet:  claude-nu gi enable"
    }
    gi-stale-note $paths
    print $"open a bound session on it:  claude-nu gi open ($paths_doc.rel)"
    if $session == null {
        # The log can never hold the turn that ran the import (Claude Code writes
        # it as the turn runs). After `gi open` the agent is back in this same
        # session and still holds that turn, so it can close the gap itself —
        # the file's note can only state it. Only for the live session: an older
        # session's log is complete, and its turns are in nobody's context.
        print $"the import stops before this turn — after resuming, ask the agent to append the tail from its context."
    }
    # `doc` and status's `canvas` are different questions: the canvas this call
    # wrote, versus the one the calling session is bound to (usually none).
    gi-status --root $root | insert doc ($paths_doc.abs | cwd-relative)
}

# The `session:` value from a canvas's YAML frontmatter, or null when the file
# has no frontmatter or no session key. Both origins write it: export-session
# for a canvas written by `gi import`, and `gi open` for every
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

# Write `session: <sid>` into a canvas's frontmatter — replacing the key when
# it is already there (that is `--new-session`), adding it to an existing block,
# or creating the block when the file has none. Why stamp the file rather than
# keep a side record: an imported canvas already carries this key, so
# both origins end up with one mechanism, and the binding travels with the file
# — move or copy a canvas and it still names its session. Exported for tests.
export def gi-stamp-session [file: path, sid: string]: nothing -> nothing {
    let split = gi-frontmatter-split $file
    if $split.head == null {
        return ($"---\nsession: ($sid)\n---\n\n($split.body)" | save --force $file)
    }
    # The rewrite happens inside head only, so a line of prose that happens to
    # start with `session:` is never touched. The body is passed through
    # untouched, trailing newline and all.
    let head = $split.head
    | if ($in =~ '(?m)^session:') { str replace --regex --multiline '^session:.*$' $"session: ($sid)" } else { $"($in)\nsession: ($sid)" }
    $"($head)\n---\n($split.body)" | save --force $file
}

# A canvas cut at its frontmatter fence: `head` is the opening `---` plus the
# keys and `body` is everything after the closing one, or head is null when the
# file has no frontmatter at all. One place defines what a well-formed canvas
# looks like, so `--fork` can ask the question of the *source* before copying
# anything, instead of the copy discovering it while being stamped.
def gi-frontmatter-split [file: path]: nothing -> record {
    let raw = open --raw $file
    if not ($raw | str starts-with "---\n") { return {head: null, body: $raw} }
    let parts = $raw | split row --number 2 "\n---\n"
    if ($parts | length) < 2 {
        # Say which file and what is wrong with it. Indexing past the split
        # would throw "Row number too large", which names neither.
        error make --unspanned {
            msg: $"canvas frontmatter is not closed: ($file)"
            help: "the block opened by `---` needs a closing `---` line of its own before the body"
        }
    }
    {head: $parts.0, body: $parts.1}
}

# Which session a launch runs on, decided from what the canvas records. Split
# out of gi-launch for the same reason as gi-launch-args: that command ends in
# an exec and can't be tested, and this decision — mint or resume — is the whole
# of "one canvas, one session, for life".
# - resume: the canvas names a session and nothing overrides it.
# - sid: that session, or a fresh id.
# - replaced: the id --new-session is dropping, null otherwise. Named because
#   the canvas is untracked by default, so git may not hold the old id and
#   nothing else records it.
# Exported for tests.
export def gi-session-plan [recorded: any, --new-session]: nothing -> record {
    let resume = (not $new_session) and ($recorded | is-not-empty)
    {
        sid: (if $resume { $recorded } else { random uuid })
        resume: $resume
        replaced: (if not $resume { $recorded })
    }
}

# The `claude` flags a canvas launch owns: the session it binds, the settings
# that carry the style and the hook, and the system-prompt line that names the
# canvas. Short forms included — `-c` and `-r` pick a session as surely as their
# long spellings.
const GI_OWNED_FLAGS = ["--settings" "--session-id" "--resume" "-r" "--continue" "-c" "--fork-session" "--name" "--append-system-prompt"]

# The pass-through's one rule: it may not carry a flag gi sets itself. Why it has
# to fail and not just lose: `claude` takes the LAST --settings, so a forwarded
# one wins and takes the style and the Stop hook with it — gi half on, the same
# state the style-exists check in gi-launch refuses to allow, only silent. A
# forwarded --resume/--session-id likewise unbinds the launch from the canvas
# that named it. --append-system-prompt is the same failure again and measured:
# given two, `claude` keeps only the last, so a forwarded one drops the line that
# names the canvas and the session is back to guessing. `=` split so
# `--settings={...}` is caught too. Called once, at the top of gi-launch, before
# the canvas is written.
export def gi-reject-owned-flags [extra: list<string>]: nothing -> nothing {
    let owned = $extra | where ($it | split row "=" | first) in $GI_OWNED_FLAGS
    if ($owned | is-not-empty) {
        error make --unspanned {
            msg: $"gi sets ($owned | str join ', ') itself — a canvas launch cannot pass it through"
            help: "the canvas binds the session (--session-id/--resume/--name) and carries the style and the hook (--settings); to work in another session, open another canvas"
        }
    }
}

# The `claude` flags that bind a launch to a canvas's session. Split out of
# gi-launch because that command ends in an exec and can't be tested; this is
# the part worth pinning. --session-id declares an id gi just minted (the canvas
# records it, so the canvas can be reopened); --resume returns to one the canvas
# already carried. --name puts the canvas in the prompt box, the /resume picker,
# and the terminal title, so the session says which canvas it belongs to.
# --append-system-prompt says the same thing to the agent, and is the only one of
# the three it can actually read. Why not leave that to $env.GI_CANVAS, which the
# launch also sets: an environment variable is not in the model's context. The
# style pointed at it, so every session opened by spending a shell call to
# resolve it — and observed repeatedly, the agent guessed the variable's name
# wrong, read an empty string, and fell back to listing directories hunting for a
# canvas. The path is known here and text costs nothing. GI_CANVAS stays for the
# Stop hook and `gi status`: those are processes, and that is where a process
# reads it.
# `extra` is the caller's own `claude` flags, appended last and untouched — gi
# has no opinion on them beyond the one rule gi-reject-owned-flags states.
export def gi-launch-args [sid: string, doc: string, --resume, ...extra: string]: nothing -> list<string> {
    if $resume { ["--resume" $sid] } else { ["--session-id" $sid] }
    | append ["--name" $doc]
    | append ["--append-system-prompt" $"This session's canvas is `($doc)` — the one file the Canvas output style is about. Read it before your first answer; do not search for it."]
    | append $extra
}

# Launch Claude Code bound to one canvas — the only thing that turns gi on.
# Everything travels with the launch and nothing is left in the repo:
# `--settings` carries the Canvas style and (unless --no-hook) the Stop hook for
# this process only, and $env.GI_CANVAS names the canvas for the agent and for
# the hook, which inherits it as a child process.
# One canvas holds one session for life: a canvas with no `session:` in its
# frontmatter gets one minted here (`--session-id`) and written in; one that has
# it is resumed. Why `--resume` and not `--fork-session`: the id must keep
# matching the frontmatter, or the canvas can't be reopened a third time.
def gi-launch [
    --doc: path # The canvas; created from the template when new
    --root: path # Run gi in this directory instead of here (default: your cwd)
    --hook # Carry the Stop-hook floor into the session
    --new-session # Mint a fresh session id, overwriting the one the canvas records
    --fork # Open a copy of the named canvas instead, on a session of its own
    --extra: list<string> = [] # Flags forwarded to `claude` untouched
]: nothing -> nothing {
    gi-reject-owned-flags $extra
    # Read the run directory off the flag before the next line shadows it.
    let dir = gi-run-dir $root
    let root = $root | default (gi-repo-root) | path expand
    # outputStyle names a style file that must be on disk, or the session starts
    # with no style and gi is silently half on. So seed it — copy-if-absent, an
    # edited style is never touched — rather than refuse. At the repo root and
    # not at the run directory: Claude Code searches every `.claude/output-styles/`
    # from the working directory up to the root, so one seed serves the whole
    # repo instead of one per subdirectory a canvas was ever opened from. Seeding
    # cannot fail on anything the user typed; every check that can (the flags
    # above, the fork source below) either runs before it or before its own
    # write, so no failure leaves a canvas behind.
    let paths = gi-paths $root
    gi-seed $paths
    # Copy-if-absent leaves an already-seeded file alone, so seeding is exactly
    # what cannot fix drift — say so here, where the session about to start is
    # the one that will run on the older text.
    gi-stale-note $paths
    let doc = $doc | default (gi-default-doc)
    # The copy is made here and not in `gi open` so everything below — the
    # session plan, the stamp, GI_CANVAS, --name — sees only the file being
    # opened. From this line on a fork is an ordinary canvas.
    let paths_doc = gi-doc-path $dir $doc
    | if $fork { gi-doc-path $dir (gi-fork-canvas $in.abs) } else { }
    let doc_abs = $paths_doc.abs
    let doc_rel = $paths_doc.rel
    # The canvas exists before a session is bound to it: a new one is stamped
    # with the id gi mints, and there must be a file to stamp.
    if not ($doc_abs | path exists) {
        mkdir ($doc_abs | path dirname)
        copy-file $GI_HEADER_SRC $doc_abs
    }
    # One canvas, one session, for life — and the canvas says which case this
    # is, so the caller does not. A `session:` in its frontmatter is one to
    # return to; without one, gi mints an id and writes it in. --new-session
    # declines to read it, which mints and overwrites instead: a session file
    # can be deleted or expire, and `claude --resume` then fails on an id the
    # canvas can do nothing about.
    # A fork mints for the same reason --new-session does: the copy arrives
    # carrying the source's id, and resuming that would put both canvases in one
    # conversation — the thing forking exists to avoid. The id it drops is the
    # source's, so the note below names the session this fork grew out of.
    let plan = gi-session-plan (gi-frontmatter-session $doc_abs) --new-session=($new_session or $fork)
    if not $plan.resume {
        if ($plan.replaced | is-not-empty) {
            print (if $fork {
                $"note: ($doc_rel) is a fork of session (gi-session-key $plan.replaced) and starts one of its own"
            } else {
                $"note: replacing session (gi-session-key $plan.replaced) recorded in ($doc_rel)"
            })
        }
        gi-stamp-session $doc_abs $plan.sid
    }
    # Same guard the hook enforces, surfaced before the session starts — a
    # branch switch now beats being blocked mid-session with commits already made.
    let branch = gi-branch $root
    if $hook and ($branch in $GI_PROTECTED_BRANCHES) {
        print $"note: this repo is on ($branch) — gi commits belong on a work branch; the Stop hook will block turns until you switch."
    }
    let args = gi-launch-args $plan.sid $doc_rel --resume=$plan.resume ...$extra
    print $"canvas ($doc_rel), session (gi-session-key $plan.sid)(if $hook { '' } else { ', no Stop hook' })"
    # cd only matters when --root sent the launch elsewhere; without it this is
    # already where the user stands. It is not needed to find the style: Claude
    # Code loads project output styles from every `.claude/output-styles/`
    # between the working directory and the repository root, so the seed at the
    # root resolves from any subdirectory of it.
    do {
        cd $dir
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
    # Paths pass through cwd-relative. This revises "data here; display is the
    # caller's business", which kept them absolute: the record's only consumer
    # is a human terminal, where a wide column truncates exactly the segment
    # that differs, and no script reads these fields — the hook reads
    # $env.GI_CANVAS itself, which stays absolute.
    {
        # Read from the environment, not from a file: activation is per session,
        # so "is gi on" is a property of who is asking, not of the repo.
        canvas: ($env.GI_CANVAS? | if ($in | is-not-empty) { cwd-relative } else { })
        style: ($paths.style_dst | cwd-relative)
        skills: (gi-skill-seeds $paths | get dst | each {|p| $p | cwd-relative })
        stale: (gi-stale $paths | each {|p| $p | cwd-relative })
    }
}

# Stop-hook body. Reads the event JSON on stdin and returns either nothing
# (allow the turn to end) or the block-decision JSON string. `nu -c` renders
# the return value to stdout, which is the Stop hook's control channel; the
# command always exits 0, per the contract. Returning (not printing) keeps it
# unit-testable. The single `to json` lives here, next to the contract it
# serves — the rules deal in records only. Also accepts nothing: run by hand
# with no stdin, the normalization below treats it as an empty event.
# Exported so the hook can import it, but kept out of mod.nu: nobody types this.
export def "gi check" []: [string -> any, nothing -> any] {
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

# The actual gi rules, free to throw; `gi check` owns the exit-0 contract.
def gi-check-rules []: record -> any {
    let payload = $in
    # $env.GI_CANVAS is the activation itself: `gi open` set it on
    # the session they launch, and the hook inherits it as a child process. It is
    # also the only thing that makes a block actionable — the reason has to name
    # the canvas to move the answer into. Unset, there is no canvas, no gi
    # session, and nothing to enforce; the turn ends. No second source to consult.
    let canvas = $env.GI_CANVAS? | default ""
    if ($canvas | is-empty) { return }

    # The chat aside, before every rule: the user asked something in chat and
    # said the answer stays there, so this turn is not canvas work at all. It
    # writes no file and makes no commit, which is also why it clears the branch
    # guard below — that guard protects the trunk from commits, and there are
    # none here.
    if (gi-off-canvas ($payload.transcript_path? | default "")) { return }

    # Two questions, two values, the same split as in the commands: the session's
    # own directory is what a path is shortened against (that is where the agent
    # stands), and the repo around it is what the branch guard reads.
    let dir = $payload.cwd? | default $env.PWD | path expand
    let root = gi-repo-root $dir

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

    # Name the canvas the short way when it is under the session's directory —
    # the agent reads this path in a message, and the absolute form is noise
    # there. Relative to that directory and not to the repo root, or the agent
    # is handed a path that does not resolve from where it is standing.
    let doc = if ($canvas | str starts-with $"($dir)/") { $canvas | path relative-to $dir } else { $canvas }
    # The escape hatch is safe by construction: the blocked message is already
    # on the user's screen, and the stop_hook_active guard ends the turn on the
    # follow-up whatever it says — a misfire can redirect one reply, never trap
    # the agent.
    let reason = $"Chat may carry only one short line — `done`, a status note, or a pointer to where the answer landed. Move the full answer into `($doc)` and commit it; leave only that one line in chat. If this block looks like a misfire — wrong canvas, no gi work in this session — don't move anything: reply with one short line telling the user to read your previous message above in the chat and to check the session's canvas \(`claude-nu gi`)."
    {decision: "block" reason: $reason}
}

# The marker that takes one exchange off the canvas, written by the user at the
# start of their message: `chat: what does this flag do?`.
const GI_CHAT_MARKER = "chat:"

# True when the user's last message opens with the marker — the exchange is an
# aside: answer in chat, write nothing to the canvas, commit nothing.
# Why the user's message and never the agent's: a marker the agent could write
# is the agent lifting its own floor, which is the one thing this hook exists to
# prevent. The user's words reach the hook only through the transcript, so the
# event's `transcript_path` is where the marker is read from.
# Why the LAST authored user message: it is the one that opened this turn.
# Tool-result records are user-type too, so the filter that `messages` uses
# decides what counts as a human turn — one definition, not a second one here.
# No path (a hand-run `gi check`, an event without the field) leaves the floor
# up: the aside is something the user asks for, not a state we assume. A path
# that exists but cannot be read is not caught — `gi check` turns it into a
# loud block.
export def gi-off-canvas [transcript: string]: nothing -> bool {
    if ($transcript | is-empty) or not ($transcript | path exists) { return false }
    # --contains screens the raw lines before decoding: only user records can
    # carry the marker, and this parse runs at every turn end.
    $transcript
    | read-session-records --contains '"type":"user"'
    | user-message-texts
    | last 1 | get 0? | default ""
    | str trim | str lowercase | str starts-with $GI_CHAT_MARKER
}

# Line breaks allowed in a chat message, alongside the character budget.
const GI_HOOK_MAX_BREAKS = 3

# The allow-rule: what may stand alone in chat. True (allowed) when, after trim,
# the message is empty, or fits the budget: at most 3 line breaks and
# GI_HOOK_MAX_LEN characters. Size is the whole floor — a real answer exceeds it.
# Why not one line: a status note plus a pointer is two lines, and a floor that
# forbids the second one is not measuring the thing it cares about.
# Not a link signal (backtick, `→`, filename) because: it made a path the price
# of every chat line, so a short honest status note ("waiting on the background
# agent") was blocked even though it hid nothing from the canvas. Demanding a
# path where there is none teaches the agent to invent one, which is worse than
# the sentence it was meant to prevent.
# Why a budget env-var: "short" is fuzzy; GI_HOOK_MAX_LEN makes the threshold
# tunable without editing the hook (legacy prefix kept — deployed sessions
# already use it).
export def gi-allowed [message: string]: nothing -> bool {
    let text = $message | str trim
    if ($text | is-empty) { return true }

    let max = $env.GI_HOOK_MAX_LEN? | default 480 | into int
    (($text | lines | length) <= ($GI_HOOK_MAX_BREAKS + 1)) and (($text | str length) <= $max)
}
