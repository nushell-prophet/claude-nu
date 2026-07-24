# gi — per-repo setup for the gi protocol, with an opt-in Stop hook.
#
# The gi protocol moves all "what/why" into git: the diff and the commit body
# carry the record, the chat carries almost nothing. `gi enable` does the
# setup: it seeds the Canvas output style, the gi skills, and the working doc,
# and turns the style on in settings.local.json. The style is proactive
# shaping only — it rests on prose and the agent drifts back to long chat
# answers. `gi enable --hook` adds a structural barrier on top of it: a Claude
# Code Stop hook that blocks the turn when the final chat message is more than
# `done`/`noted` or a short pointer, and tells the agent to move the answer
# into the recorded working doc. It also blocks turns that end on main/master:
# gi commits are internal working history — they reach a public branch only
# squash-merged, after finalization. The hook is opt-in because the floor only
# fits strict gi sessions; the user often returns to plain chat, and the setup
# alone must not block those turns. Everything is per-repo, so the classic
# mode is untouched.
#
# Renamed from `gi-hook`: once enable stopped installing the hook by default,
# the old name promised a hook it no longer delivered. Legacy spellings remain
# where deployed copies depend on them — see GI_MARKERS and the GI_HOOK_* env
# keys. Settings files still carrying the old `gi-hook check` command must
# re-run `gi enable` (which rewrites the entry); the command alias itself is
# gone.

use sessions.nu [export-session resolve-session-file]

# Substrings that identify our Stop entry inside settings.local.json. Why: the
# command line is the only stable signature to match on for idempotent enable
# and surgical disable — see `gi disable`. Two spellings: entries written
# before the gi-hook → gi rename embed the old command, and enable/disable
# must still recognize them for refresh and removal.
const GI_MARKERS = ["gi check" "gi-hook check"]

# The output-style name gi enable installs. Why a const: enable writes it into
# settings.local.json (outputStyle) and disable removes it only if it still
# matches — so a user's own outputStyle is never clobbered. Matches the `name:`
# frontmatter in the seeded style file.
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

# Every path gi touches, in one record.
# - settings: per-repo, per-machine file the hook lives in. Why this file: it is
#   already gitignored by Claude Code, so the hook stays local — it never
#   reaches another checkout or the classic mode.
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
        settings: ($root | path join ".claude" "settings.local.json")
        template_src: $GI_HEADER_SRC
        style_src: ($GI_MODULE_DIR | path join "gi-md-src" "canvas-output-style.md")
        style_dst: ($root | path join ".claude" "output-styles" "canvas.md")
        skills_src: ($GI_MODULE_DIR | path join "gi-md-src" "skills")
        skills_dst: ($root | path join ".claude" "skills")
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

# The working doc recorded in settings (env.GI_HOOK_DOC), or null. The doc name
# is timestamped or user-chosen, so it can't be recomputed — it must be
# persisted; the sole reader is this command (status and check both come through
# here), so a re-enable with a new doc applies on the next Stop event, no
# session restart. Why the `env` key and not a custom one: it is schema-valid
# in settings.local.json, and Claude Code exports it into the session — the
# agent itself can locate the canvas via $env.GI_HOOK_DOC. The key keeps the
# legacy GI_HOOK_ prefix: seeded style files and running sessions already read
# it, and renaming would orphan every deployed copy.
def gi-doc [settings: record]: nothing -> any {
    $settings.env?.GI_HOOK_DOC?
}

# True if a Stop entry is one we installed (matches by command signature).
def gi-is-ours []: record -> bool {
    $in.hooks?
    | default []
    | any {|h|
        let cmd = $h.command? | default ""
        $GI_MARKERS | any {|m| $cmd | str contains $m }
    }
}

def gi-open-settings [path: path]: nothing -> record {
    if ($path | path exists) { open $path } else { {} }
}

# The directory whose .claude/settings.local.json governs the event's cwd:
# the nearest ancestor whose settings file carries our Stop entry — a session
# may be rooted at a monorepo subproject that enable targeted with --root, and
# an ancestor short of it may hold unrelated local settings (permissions etc.)
# that must not shadow the gi-enabled one. Null when no file in scope carries
# the entry. Why match on the entry, not mere file presence: it makes disable
# effective immediately — Claude Code snapshots hook config at session start,
# so after a mid-session `gi disable` the snapshotted hook keeps firing; the
# live settings file is the truth, and with no entry anywhere check stands
# down. The walk is bounded by the toplevel: crossing it would adopt an
# unrelated outer settings file (e.g. ~/.claude) as this repo's.
def gi-settings-root [dir: path]: nothing -> any {
    let top = gi-repo-root $dir
    generate {|d|
        if $d == $top or ($d | path dirname) == $d { {out: $d} } else { {out: $d next: ($d | path dirname)} }
    } ($dir | path expand)
    | where {|d|
        gi-open-settings ($d | path join ".claude" "settings.local.json")
        | $in.hooks?.Stop?
        | default []
        | any {|e| $e | gi-is-ours }
    }
    | get 0?
}

# The four gi actions, surfaced as tab completions on the positional below.
def "nu-complete gi-actions" []: nothing -> table {
    [
        [value description];
        [enable "seed the style, skills, and working doc; --hook adds the Stop hook"]
        [disable "remove the hook and outputStyle (seeded files stay)"]
        [status "show what is installed"]
        [check "hook body — reads the Stop event JSON on stdin"]
    ]
}

# gi — set up the gi protocol in this repo; --hook adds the Stop-hook floor.
# One command, one positional action (tab-completes); with no action it
# reports status. Why one command, not four subcommands: the four were just
# verbs on the same object — a positional with a completer is the same call
# surface (`gi enable` still parses) with a single export to maintain.
# Named `main` because a module can't export a command named the same as the
# module — importing this file yields the `gi` command.
export def main [
    action?: string@"nu-complete gi-actions" # enable | disable | status | check (default: status)
    doc?: path # enable only: working-doc path (default: keep the recorded one, else gi/canvas-<timestamp>.md; with --from-session gi/session-<id>.md)
    --root: path # Repo root (default: git top-level); ignored by check
    --force # enable only: overwrite the seeded style and skills with the module's versions
    --hook # enable only: also install the Stop hook (the hard floor)
    --from-session # enable only: start the working doc from this session's dialogue
    --commit # --from-session only: commit the imported doc
    --gitignore # --from-session only: keep the imported doc out of git
    --tools # --from-session only: keep tool calls in the import as one-line placeholders
]: any -> any {
    let event = $in # check reads the Stop event here; the others ignore it
    # Every enable-only option in one guard. Why a table: each option needs its
    # own span for the error label, and six copies of the same five-line `if`
    # buried the two guards below that actually say something.
    let misplaced = [
        [given msg hint span];
        [($doc != null) "a working-doc path only makes sense with enable" "gi enable <doc>" (metadata $doc).span]
        [$force "--force only makes sense with enable" "gi enable --force" (metadata $force).span]
        [$hook "--hook only makes sense with enable" "gi enable --hook" (metadata $hook).span]
        [$from_session "--from-session only makes sense with enable" "gi enable --from-session" (metadata $from_session).span]
        [$commit "--commit only makes sense with enable" "gi enable --from-session --commit" (metadata $commit).span]
        [$gitignore "--gitignore only makes sense with enable" "gi enable --from-session --gitignore" (metadata $gitignore).span]
        [$tools "--tools only makes sense with enable" "gi enable --from-session --tools" (metadata $tools).span]
    ]
    | where given
    if $action != "enable" and ($misplaced | is-not-empty) {
        let bad = $misplaced | first
        error make {msg: $bad.msg label: {text: $"drop this, or use: ($bad.hint)" span: $bad.span}}
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
        "enable" => (gi-enable --root $root --doc $doc --force=$force --hook=$hook --from-session=$from_session --commit=$commit --gitignore=$gitignore --tools=$tools)
        "disable" => (gi-disable --root $root)
        "check" => ($event | gi-check)
        _ => {
            error make {
                msg: $"unknown gi action: ($action)"
                label: {text: "expected enable, disable, status, or check" span: (metadata $action).span}
            }
        }
    }
}

# Set up the gi protocol in this repo's .claude/settings.local.json: seed the
# style, skills, and working doc, and turn the Canvas style on. With --hook,
# also install the Stop hook. Idempotent: a second enable adds no duplicate.
def gi-enable [
    --root: path # Repo root to install into (default: git top-level)
    --doc: path # Working-doc path, relative to root (absolute also accepted)
    --force # Overwrite the seeded style and skills with the module's versions
    --hook # Also install the Stop hook
    --from-session # Start the working doc from this session's dialogue
    --commit # Commit the imported doc
    --gitignore # Keep the imported doc out of git
    --tools # Keep tool calls in the import as one-line placeholders
]: nothing -> record {
    let root = $root | default (gi-repo-root) | path expand
    let paths = gi-paths $root
    let settings = gi-open-settings $paths.settings
    let sid = if $from_session { gi-session-id }

    # Resolve the working doc: explicit arg wins; else an import gets its own
    # session-keyed name — re-running it in one session refreshes one file, and
    # the repo's older canvas (the recorded doc) is left alone; else keep the
    # recorded one so re-enable is idempotent; else mint a timestamped default.
    # Stored root-relative when under root — the hook runs with cwd at the
    # project, so the short form works in the block message and survives a
    # checkout move.
    let doc = $doc
        | default (if $from_session { $"gi/session-(gi-session-key $sid).md" })
        | default (gi-doc $settings)
        | default $"gi/canvas-(date now | format date '%J_%Q').md"
    let doc_abs = $root | path join $doc
    # Expand the dirname, not the whole path: the doc may not exist yet, and
    # `path expand` resolves symlinks only for paths that exist. This keeps an
    # absolute doc arriving through a symlink (cozy's ~/repos) root-relative.
    let doc_abs = $doc_abs | path dirname | path expand | path join ($doc_abs | path basename)
    let doc = if ($doc_abs | str starts-with $"($root)/") { $doc_abs | path relative-to $root } else { $doc_abs }

    # Build the import before anything is written: a session that can't be read
    # must not leave settings pointing at a doc that was never created.
    let imported = if $from_session {
        if ($doc_abs | path exists) {
            error make --unspanned {
                msg: $"working doc already exists: ($doc_abs)"
                help: "the import is the doc's starting content and won't overwrite work already in it — delete the file to re-import, or name another doc: gi enable <doc> --from-session"
            }
        }
        gi-import-text $sid --tools=$tools
    }

    # The hook is opt-in: --hook installs it; plain enable leaves the on/off
    # state alone but still refreshes an already-installed entry. Why refresh:
    # the command embeds the module path, so re-enable must refresh an entry
    # recorded from a since-moved checkout — a stale path fails at `use` time,
    # outside anything the module can catch. Refresh drops any prior entry of
    # ours (old spelling included) before appending the current one.
    let prior = $settings.hooks?.Stop? | default []
    let install = $hook or ($prior | any {|e| $e | gi-is-ours })
    let stop = $prior
        | where {|e| not ($e | gi-is-ours) }
        | if $install { append {hooks: [{type: "command" command: $GI_COMMAND}]} } else { }

    let hooks = $settings.hooks? | default {} | upsert Stop $stop
    let env_block = $settings.env? | default {} | upsert GI_HOOK_DOC $doc
    mkdir ($paths.settings | path dirname)
    # Set outputStyle in the same write. Why: the style shapes what gets
    # written proactively; the optional hook is the hard floor on top — LLMs
    # are non-deterministic, so strict sessions add the floor via --hook.
    $settings
    | upsert hooks $hooks
    | upsert env $env_block
    | upsert outputStyle $GI_STYLE
    | save --force $paths.settings

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

    # The style is read once at session start, so it won't apply until /clear or
    # a new session; the hook (when installed) takes effect immediately.
    let mode = if $install { "with the Stop hook" } else { "setup only — `gi enable --hook` adds the Stop hook" }
    print $"gi enabled \(($mode)\). Run /clear or start a new session for the Canvas output style to load."
    if $imported != null {
        # One pasteable block instead of instructions to relay. Two gaps to
        # cover: the agent's $env.GI_HOOK_DOC was snapshotted at session start
        # (stale until /clear), and the log can never hold the turn that ran
        # the import — but the agent still has that turn in its context, so
        # telling it to append closes the gap the file's note can only state.
        print $"imported this session into ($doc_abs) — paste this to the agent:"
        print ""
        print $"  The gi canvas is now `($doc)` — ignore $env.GI_HOOK_DOC until /clear; it was snapshotted at session start. The doc ends before the turn that ran the import: append the missing tail of our dialogue to it from your context."
    }
    # Same guard the hook enforces, surfaced at opt-in time — switching now
    # beats being blocked mid-session with commits already on the branch.
    # Gated on the hook: without it nothing blocks, so there is nothing to warn about.
    let branch = gi-branch $root
    if $install and ($branch in $GI_PROTECTED_BRANCHES) {
        print $"note: this repo is on ($branch) — gi commits belong on a work branch; the Stop hook will block turns until you switch."
    }
    let status = gi-status --root $root
    # Surface drift at the moment the user is already touching gi — status
    # carries the same list, but nobody polls it.
    if not $force and ($status.stale | is-not-empty) {
        print $"note: ($status.stale | length) seeded file\(s\) differ from the module — `gi enable --force` refreshes them."
    }
    $status
}

# Remove our Stop hook, outputStyle, and recorded doc, leaving any other hooks
# intact. No-op if absent.
def gi-disable [
    --root: path # Repo root to remove from (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-repo-root) | path expand
    let path = (gi-paths $root).settings
    if not ($path | path exists) { return (gi-status --root $root) }

    # Emptied containers (hooks: {Stop: []}, env: {}) stay behind on purpose:
    # harmless in a gitignored machine-local file, and pruning them tripled
    # this body.
    gi-open-settings $path
    | if ($in.hooks?.Stop? == null) { } else {
        update hooks.Stop { where {|e| not ($e | gi-is-ours) } }
    }
    # Drop outputStyle only if it is still ours — never clobber a value the user
    # set themselves. The seeded style and working doc are left in place (user files).
    | if ($in.outputStyle? == $GI_STYLE) { reject outputStyle } else { }
    | reject env?.GI_HOOK_DOC?
    | save --force $path
    gi-status --root $root
}

# Report what gi installed in this repo. Pipeline-friendly record.
def gi-status [
    --root: path # Repo root to inspect (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-repo-root) | path expand
    let paths = gi-paths $root
    let settings = gi-open-settings $paths.settings
    let doc = gi-doc $settings
    # Paths stay absolute and present whenever recorded. Shortening them
    # against PWD made the same field change spelling with where you stand,
    # and nulling missing seed files collapsed two states into one — a null
    # doc could mean "not recorded" or "recorded but deleted", which need
    # different user actions. Data here, display is the caller's business.
    {
        hook: ($settings.hooks?.Stop? | default [] | any {|e| $e | gi-is-ours })
        settings: $paths.settings
        doc: (if $doc != null { $root | path join $doc })
        style: $paths.style_dst
        skills: (gi-skill-seeds $paths | get dst)
        stale: (gi-stale $paths)
        output_style_set: ($settings.outputStyle? == $GI_STYLE)
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
    # Not the raw event cwd: the session's cwd may have drifted into a
    # subdirectory of wherever enable wrote the settings (and recorded doc).
    let root = gi-settings-root ($payload.cwd? | default $env.PWD)
    # No live hook anywhere in scope: gi is disabled (possibly mid-session,
    # after the hook-config snapshot) or check was run by hand outside a
    # gi-enabled repo. Nothing to enforce.
    if $root == null { return }

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

    # Name the exact working doc when enable recorded one. Why: the doc name is
    # timestamped or user-chosen, so a blocked agent can't guess it; naming it
    # makes the correction actionable without a discovery step. Read fresh from
    # settings at the event's cwd — not from $env, which Claude Code snapshots
    # at session start and would go stale on a mid-session re-enable.
    let doc = gi-doc (gi-open-settings (gi-paths $root).settings)
    let doc = match ($doc | default "") {
        "" => "the working document"
        $p => $"`($p)`"
    }
    # The escape hatch is safe by construction: the blocked message is already
    # on the user's screen, and the stop_hook_active guard ends the turn on the
    # follow-up whatever it says — a stale hook can redirect one reply, never
    # trap the agent.
    let reason = $"Chat may carry only `done`/`noted` or a short pointer \(one line with a path/link). Move the full answer into ($doc) and commit it; leave only a pointer in chat. If this block looks like a misfire — stale hook, wrong doc, no gi work in this session — don't move anything: reply with one short line telling the user to read your previous message above in the chat and to check this hook \(`gi status` / `gi disable`)."
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
