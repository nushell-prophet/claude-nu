# gi — the gi protocol: seeded per repo, activated per session at launch.
#
# The gi protocol moves all "what/why" into git: the diff and the commit body
# carry the record, the chat carries almost nothing. Two commands do the work,
# and the split between them is the whole design:
#
#   gi enable          seeds files into the repo — the Canvas output style and
#                      the gi skills. Writes nothing to settings, turns nothing
#                      on, and makes no canvas: that is the launcher's job, so
#                      the two halves never write the same file.
#   gi open            launches Claude Code bound to one canvas: `--settings`
#                      carries the output style and the Stop hook for that launch
#                      alone, and $env.GI_CANVAS names the canvas. Both reach the
#                      hook, which runs as a child of that session. A canvas holds
#                      one session for life — a canvas with no session gets one
#                      minted and written in, one that has it is resumed. Which
#                      case it is, the file says; there is no second verb.
#                      `--new-session` is the way out when that session is gone
#                      (deleted, expired): it overwrites the recorded id.
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
# blocks the turn when the final chat message is more than `done`/`noted` or a
# short pointer, and blocks turns ending on main/master (gi commits are internal
# working history — they reach a public branch only squash-merged, after
# finalization). It comes with every `gi open`; `--no-hook` opens a canvas with
# the style alone.
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

# The canvas name minted when the user names none. A def and not a const: the
# timestamp has to be read when the command runs, not when the module parses.
def gi-default-doc []: nothing -> string {
    $"gi/canvas-(date now | format date '%J_%Q').md"
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
    {path: $file} | export-session --tools=$tools
    | get 0.markdown
    | str replace --multiline --no-expand '^# .+' ([(open --raw $GI_HEADER_SRC) $note] | str join "\n")
}

# The 8-char session key used in the default doc name.
def gi-session-key [session_id: string]: nothing -> string {
    $session_id | str substring 0..7
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
# The verbs: `gi enable`, `gi open`.
export def main [
    --root: path # Repo root to inspect (default: git top-level)
]: nothing -> record {
    gi-status --root $root
}

# Open a canvas: launch a session bound to it, creating the canvas from the
# template when it does not exist and continuing the session it already records
# when it has one.
export def --wrapped "gi open" [
    doc?: path # The canvas (default: gi/canvas-<timestamp>.md)
    --root: path # Repo root (default: git top-level)
    --no-hook # Launch with the Canvas style but without the Stop-hook floor
    --new-session # Start a fresh session on this canvas, overwriting the id it records
    --dangerously-skip-permissions # Pass claude's flag of the same name through
    ...rest: string # Any other flags go straight to `claude`
]: nothing -> nothing {
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
    gi-launch --root $root --doc $doc --hook=(not $no_hook) --new-session=$new_session --extra $extra
}

# Seed the gi protocol into this repo: the Canvas style and the gi skills.
# Turns nothing on — `gi open` does that, per session — and writes to
# no settings file. Re-runnable: seeded files are never clobbered.
export def "gi enable" [
    doc?: path # Where the --from-session import lands (default: gi/session-<id>.md)
    --root: path # Repo root to seed (default: git top-level)
    --force # Overwrite the seeded style and skills with the module's versions
    --from-session # Start a canvas from this session's dialogue
    --commit # Commit the imported doc
    --gitignore # Keep the imported doc out of git
    --tools # Keep tool calls in the import as one-line placeholders
]: nothing -> record {
    # What is left after the signature: the three rules that relate options to
    # each other, which no signature can state.
    # enable seeds the style and the skills; it does not make canvases. `gi open
    # <doc>` does that, and binds a session in the same breath — so a path here
    # with nothing to import would name a file enable has no reason to write.
    if $doc != null and not $from_session {
        error make {
            msg: "gi enable makes no canvas — a path here is where --from-session puts the import"
            label: {text: "to start a canvas: gi open <doc>; to import this session into it: gi enable <doc> --from-session" span: (metadata $doc).span}
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
    let root = $root | default (gi-repo-root) | path expand
    let paths = gi-paths $root
    let sid = if $from_session { gi-session-id }

    # Canvases are not enable's business: `gi open <doc>` creates one from the
    # template and binds a session to it in the same breath. Only an import
    # needs a path here, because the dialogue has to land in a file. Default is
    # session-keyed, so re-running it in one session refreshes one file and
    # leaves the repo's older canvases alone.
    let paths_doc = if $from_session {
        gi-doc-path $root ($doc | default $"gi/session-(gi-session-key $sid).md")
    }
    let doc_abs = $paths_doc.abs?

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

    if $imported != null {
        mkdir ($doc_abs | path dirname)
        $imported | save --force $doc_abs
    }

    # Seed the output style and the gi skills. Why not clobber: once they exist
    # they are the user's files — refreshing would destroy their edits. --force
    # overwrites them, because they are distributed text a module update should
    # be able to refresh.
    for seed in (gi-refresh-seeds $paths | insert overwrite $force) {
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
    # the hook arrive with `gi open`, so the next line is the whole
    # instruction. With no import there is no canvas yet — `gi open` mints one.
    print $"gi seeded in ($root)."
    if $doc_abs == null {
        print $"start a canvas:  claude-nu gi open [<doc>]"
    } else {
        print $"canvas: ($paths_doc.rel)"
        print $"open a bound session on it:  claude-nu gi open ($paths_doc.rel)"
    }
    if $imported != null {
        # The log can never hold the turn that ran the import (Claude Code writes
        # it as the turn runs). After `gi open` the agent is back in this same
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
    # imported (null without --from-session — seeding writes no canvas), versus
    # the one the calling session is bound to (usually none).
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

# Write `session: <sid>` into a canvas's frontmatter — replacing the key when
# it is already there (that is `--new-session`), adding it to an existing block,
# or creating the block when the file has none. Why stamp the file rather than
# keep a side record: a `--from-session` canvas already carries this key, so
# both origins end up with one mechanism, and the binding travels with the file
# — move or copy a canvas and it still names its session. Exported for tests.
export def gi-stamp-session [file: path, sid: string]: nothing -> nothing {
    let raw = open --raw $file
    if not ($raw | str starts-with "---\n") {
        return ($"---\nsession: ($sid)\n---\n\n($raw)" | save --force $file)
    }
    # Split at the closing fence: head is the opening `---` plus the keys. The
    # rewrite happens inside head only, so a line of prose that happens to start
    # with `session:` is never touched. The body is passed through untouched,
    # trailing newline and all.
    let parts = $raw | split row --number 2 "\n---\n"
    if ($parts | length) < 2 {
        # Say which file and what is wrong with it. Indexing past the split
        # would throw "Row number too large", which names neither.
        error make --unspanned {
            msg: $"canvas frontmatter is not closed: ($file)"
            help: "the block opened by `---` needs a closing `---` line of its own before the body"
        }
    }
    let head = $parts.0
    | if ($in =~ '(?m)^session:') { str replace --regex --multiline '^session:.*$' $"session: ($sid)" } else { $"($in)\nsession: ($sid)" }
    $"($head)\n---\n($parts.1)" | save --force $file
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

# The `claude` flags a canvas launch owns: the session it binds and the settings
# that carry the style and the hook. Short forms included — `-c` and `-r` pick a
# session as surely as their long spellings.
const GI_OWNED_FLAGS = ["--settings" "--session-id" "--resume" "-r" "--continue" "-c" "--fork-session" "--name"]

# The pass-through's one rule: it may not carry a flag gi sets itself. Why it has
# to fail and not just lose: `claude` takes the LAST --settings, so a forwarded
# one wins and takes the style and the Stop hook with it — gi half on, the same
# state the style-exists check in gi-launch refuses to allow, only silent. A
# forwarded --resume/--session-id likewise unbinds the launch from the canvas
# that named it. `=` split so `--settings={...}` is caught too. Called once, at
# the top of gi-launch, before the canvas is written.
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
# `extra` is the caller's own `claude` flags, appended last and untouched — gi
# has no opinion on them beyond the one rule gi-reject-owned-flags states.
export def gi-launch-args [sid: string, doc: string, --resume, ...extra: string]: nothing -> list<string> {
    if $resume { ["--resume" $sid] } else { ["--session-id" $sid] }
    | append ["--name" $doc]
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
    --root: path # Repo root (default: git top-level)
    --hook # Carry the Stop-hook floor into the session
    --new-session # Mint a fresh session id, overwriting the one the canvas records
    --extra: list<string> = [] # Flags forwarded to `claude` untouched
]: nothing -> nothing {
    gi-reject-owned-flags $extra
    let root = $root | default (gi-repo-root) | path expand
    let doc = $doc | default (gi-default-doc)
    let paths_doc = gi-doc-path $root $doc
    let doc_abs = $paths_doc.abs
    let doc_rel = $paths_doc.rel
    let style = (gi-paths $root).style_dst
    # outputStyle names a style file that must already be on disk here; without
    # it Claude Code would launch with no style and gi would be silently half on.
    if not ($style | path exists) {
        error make --unspanned {
            msg: $"the Canvas style is not seeded in this repo: ($style)"
            help: "run `claude-nu gi enable` first"
        }
    }
    # The canvas exists before a session is bound to it: a new one is stamped
    # with the id gi mints, and there must be a file to stamp.
    if not ($doc_abs | path exists) {
        mkdir ($doc_abs | path dirname)
        cp $GI_HEADER_SRC $doc_abs
    }
    # One canvas, one session, for life — and the canvas says which case this
    # is, so the caller does not. A `session:` in its frontmatter is one to
    # return to; without one, gi mints an id and writes it in. --new-session
    # declines to read it, which mints and overwrites instead: a session file
    # can be deleted or expire, and `claude --resume` then fails on an id the
    # canvas can do nothing about.
    let plan = gi-session-plan (gi-frontmatter-session $doc_abs) --new-session=$new_session
    if not $plan.resume {
        if ($plan.replaced | is-not-empty) {
            print $"note: replacing session (gi-session-key $plan.replaced) recorded in ($doc_rel)"
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
    let reason = $"Chat may carry only `done`/`noted` or a short pointer \(one line with a path/link). Move the full answer into `($doc)` and commit it; leave only a pointer in chat. If this block looks like a misfire — wrong canvas, no gi work in this session — don't move anything: reply with one short line telling the user to read your previous message above in the chat and to check the session's canvas \(`claude-nu gi`)."
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
