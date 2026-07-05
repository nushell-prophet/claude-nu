# gi-hook — a per-repo Stop hook that keeps the chat terse (gi protocol)
#
# The gi protocol moves all "what/why" into git: the diff and the commit body
# carry the record, the chat carries almost nothing. That rule rests on prose
# alone and fights the model's training — the agent drifts back to long chat
# answers. This installs a structural barrier instead of self-control: a
# Claude Code Stop hook that blocks the turn when the final chat message is
# more than `done`/`noted` or a short pointer, and tells the agent to move the
# answer into the repo's recorded working doc. It also blocks turns that end on
# main/master: gi commits are internal working history — they reach a public
# branch only squash-merged, after finalization. Opt-in and per-repo, so the
# classic mode is untouched.

# Substring that identifies our Stop entry inside settings.local.json. Why: the
# command line is the only stable signature to match on for idempotent enable
# and surgical disable — see `gi-hook disable`.
const GI_HOOK_MARKER = "gi-hook check"

# The output-style name gi-hook installs. Why a const: enable writes it into
# settings.local.json (outputStyle) and disable removes it only if it still
# matches — so a user's own outputStyle is never clobbered. Matches the `name:`
# frontmatter in the seeded style file.
const GI_HOOK_STYLE = "Canvas"

# Absolute path to this module's directory, resolved at parse time. Why a const:
# `path self` only runs at parse time, and the hook needs an absolute `use`
# target — relative paths are not resolved when Claude Code runs the hook.
# Deliberately NOT symlink-resolved: `path self` keeps the path as imported,
# and under cozy that is `~/repos/claude-nu` — the stable module path across
# machine states (vendored snapshot, sync-repos clone, dev-link symlink to the
# workspace). Resolving would pin the hook to one physical checkout and break
# the moment the settings file is used where that checkout does not exist;
# following the symlink at run time is exactly the dev-link contract.
const GI_HOOK_MODULE_DIR = (path self | path dirname)

# The shell command Claude Code runs for the Stop event. Single-quote the `-c`
# body so the outer shell does not expand `$in`; `--stdin` feeds the event JSON
# to nushell as `$in`. The absolute module path is required — relative paths are
# not resolved at hook time.
const GI_HOOK_COMMAND = $"nu --stdin -c 'use \"($GI_HOOK_MODULE_DIR)\"; $in | claude-nu gi-hook check'"

# Branches gi commits must never end a turn on. Why: gi history is internal
# working material — on a branch external users read, it would put them off.
# It reaches these branches only squash-merged, after finalization (see the
# git-intent-squash-archive skill).
const GI_HOOK_PROTECTED_BRANCHES = ["main" "master"]

# Repo root (git top-level) of dir — default PWD — falling back to dir itself
# outside a repo. Both branches yield a physical (symlink-resolved) path — git
# canonicalizes --show-toplevel itself. Callers expand a user-given --root to
# match, so every path comparison downstream stays within one path family.
def gi-hook-repo-root [dir?: path]: nothing -> path {
    let dir = $dir | default $env.PWD
    let top = do { ^git -C $dir rev-parse --show-toplevel } | complete
    if $top.exit_code == 0 { $top.stdout | str trim } else { $dir | path expand }
}

# The directory whose .claude/settings.local.json governs the event's cwd:
# the nearest ancestor carrying that file — a session may be rooted at a
# monorepo subproject that enable targeted with --root — falling back to the
# repo toplevel (nothing recorded yet, or enable ran there). The walk is
# bounded by the toplevel: crossing it would adopt an unrelated outer settings
# file (e.g. ~/.claude) as this repo's.
def gi-hook-settings-root [dir: path]: nothing -> path {
    let top = gi-hook-repo-root $dir
    generate {|d|
        if $d == $top or ($d | path dirname) == $d { {out: $d} } else { {out: $d next: ($d | path dirname)} }
    } ($dir | path expand)
    | where {|d| $d | path join ".claude" "settings.local.json" | path exists }
    | get 0?
    | default $top
}

# Current branch at root, or null outside a repo / on detached HEAD — nothing
# to protect there, so the branch guard passes.
def gi-hook-branch [root: path]: nothing -> any {
    let out = do { ^git -C $root branch --show-current } | complete
    let branch = $out.stdout | str trim
    if $out.exit_code == 0 and ($branch | is-not-empty) { $branch }
}

# Every path gi-hook touches, in one record.
# - settings: per-repo, per-machine file the hook lives in. Why this file: it is
#   already gitignored by Claude Code, so the hook stays local — it never
#   reaches another checkout or the classic mode.
# - template_src: the gi working-doc seed; its destination is chosen per-enable
#   (see gi-hook-enable), so only the src lives here.
# - style: the Canvas output style. Why distribute a local copy: gi-hook is
#   vendored on its own, so it must carry the style itself rather than depend on
#   a Claude plugin being installed — `enable` drops it as a per-repo project
#   style. The srcs ship inside the module, so they vendor with it.
# - skills: the gi skills, seeded the same way. Why: project-level
#   .claude/skills needs no plugin install — file presence at session start IS
#   activation — and the style names git-intent-squash-archive, so seeding
#   makes that reference real in any gi-enabled repo.
def gi-hook-paths [root: path]: nothing -> record {
    {
        settings: ($root | path join ".claude" "settings.local.json")
        template_src: ($GI_HOOK_MODULE_DIR | path join "gi-md-src" "canvas-header.md")
        style_src: ($GI_HOOK_MODULE_DIR | path join "gi-md-src" "canvas-output-style.md")
        style_dst: ($root | path join ".claude" "output-styles" "canvas.md")
        skills_src: ($GI_HOOK_MODULE_DIR | path join "gi-md-src" "skills")
        skills_dst: ($root | path join ".claude" "skills")
    }
}

# The bundled skills as [src dst] seed rows for enable's copy-if-absent loop.
# Enumerated from disk, not hardcoded: adding a skill under gi-md-src/skills
# is the whole change.
def gi-hook-skill-seeds [paths: record]: nothing -> table {
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
def gi-hook-refresh-seeds [paths: record]: nothing -> table {
    [[src dst]; [$paths.style_src $paths.style_dst]]
    | append (gi-hook-skill-seeds $paths)
}

# Seeded files whose content differs from the module source. Why content
# compare, not a version field: copy-if-absent pins a consumer repo to
# whatever was current at first enable, and nothing else ever signals drift.
# "Differs" covers a user edit too — the two are indistinguishable, and
# --force resolves both in the module's favor; that is what --force means.
def gi-hook-stale [paths: record]: nothing -> list {
    gi-hook-refresh-seeds $paths
    | where {|s| ($s.dst | path exists) and (open --raw $s.dst) != (open --raw $s.src) }
    | get dst
}

# The working doc recorded in settings (env.GI_HOOK_DOC), or null. The doc name
# is timestamped or user-chosen, so it can't be recomputed — it must be
# persisted; the sole reader is this command (status and check both come through
# here), so a re-enable with a new doc applies on the next Stop event, no
# session restart. Why the `env` key and not a custom one: it is schema-valid
# in settings.local.json, and Claude Code exports it into the session — the
# agent itself can locate the canvas via $env.GI_HOOK_DOC.
def gi-hook-doc [settings: record]: nothing -> any {
    $settings.env?.GI_HOOK_DOC?
}

# True if a Stop entry is one we installed (matches by command signature).
def gi-hook-is-ours []: record -> bool {
    $in.hooks?
    | default []
    | any {|h| ($h.command? | default "") | str contains $GI_HOOK_MARKER }
}

def gi-hook-open-settings [path: path]: nothing -> record {
    if ($path | path exists) { open $path } else { {} }
}

# The four gi-hook actions, surfaced as tab completions on the positional below.
def "nu-complete gi-hook-actions" []: nothing -> table {
    [
        [value description];
        [enable "install the Stop hook in this repo"]
        [disable "remove it (leaves any other hooks intact)"]
        [status "show whether it is installed"]
        [check "hook body — reads the Stop event JSON on stdin"]
    ]
}

# gi-hook — install/remove a per-repo Stop hook that enforces terse chat (gi
# protocol). One command, one positional action (tab-completes); with no action
# it reports status. Why one command, not four subcommands: the four were just
# verbs on the same object — a positional with a completer is the same call
# surface (`gi-hook enable` still parses) with a single export to maintain.
# Named `main` because a module can't export a command named the same as the
# module — importing this file yields the `gi-hook` command.
export def main [
    action?: string@"nu-complete gi-hook-actions" # enable | disable | status | check (default: status)
    doc?: path # enable only: working-doc path (default: keep the recorded one, else gi/canvas-<timestamp>.md)
    --root: path # Repo root (default: git top-level); ignored by check
    --force # enable only: overwrite the seeded style and skills with the module's versions
]: any -> any {
    let event = $in # check reads the Stop event here; the others ignore it
    if $doc != null and $action != "enable" {
        error make {
            msg: "a working-doc path only makes sense with enable"
            label: {text: "drop this, or use: gi-hook enable <doc>" span: (metadata $doc).span}
        }
    }
    if $force and $action != "enable" {
        error make {
            msg: "--force only makes sense with enable"
            label: {text: "drop this, or use: gi-hook enable --force" span: (metadata $force).span}
        }
    }
    match $action {
        null | "status" => (gi-hook-status --root $root)
        "enable" => (gi-hook-enable --root $root --doc $doc --force=$force)
        "disable" => (gi-hook-disable --root $root)
        "check" => ($event | gi-hook-check)
        _ => {
            error make {
                msg: $"unknown gi-hook action: ($action)"
                label: {text: "expected enable, disable, status, or check" span: (metadata $action).span}
            }
        }
    }
}

# Install the Stop hook into this repo's .claude/settings.local.json.
# Idempotent: a second enable does not add a duplicate.
def gi-hook-enable [
    --root: path # Repo root to install into (default: git top-level)
    --doc: path # Working-doc path, relative to root (absolute also accepted)
    --force # Overwrite the seeded style and skills with the module's versions
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root) | path expand
    let paths = gi-hook-paths $root
    let settings = gi-hook-open-settings $paths.settings

    # Resolve the working doc: explicit arg wins; else keep the recorded one so
    # re-enable is idempotent; else mint a timestamped default. Stored
    # root-relative when under root — the hook runs with cwd at the project, so
    # the short form works in the block message and survives a checkout move.
    let doc = $doc | default (gi-hook-doc $settings) | default $"gi/canvas-(date now | format date '%J_%Q').md"
    let doc_abs = $root | path join $doc
    # Expand the dirname, not the whole path: the doc may not exist yet, and
    # `path expand` resolves symlinks only for paths that exist. This keeps an
    # absolute doc arriving through a symlink (cozy's ~/repos) root-relative.
    let doc_abs = $doc_abs | path dirname | path expand | path join ($doc_abs | path basename)
    let doc = if ($doc_abs | str starts-with $"($root)/") { $doc_abs | path relative-to $root } else { $doc_abs }

    # Drop any prior entry of ours before appending the current one, instead of
    # skipping when the marker matches: the command embeds the module path, so
    # re-enable must refresh an entry recorded from a since-moved checkout —
    # a stale path fails at `use` time, outside anything the module can catch.
    let stop = $settings.hooks?.Stop? | default []
        | where {|e| not ($e | gi-hook-is-ours) }
        | append {hooks: [{type: "command" command: $GI_HOOK_COMMAND}]}

    let hooks = $settings.hooks? | default {} | upsert Stop $stop
    let env_block = $settings.env? | default {} | upsert GI_HOOK_DOC $doc
    mkdir ($paths.settings | path dirname)
    # Set outputStyle alongside the hook so the proactive style and the reactive
    # hook turn on together. Why both: the style shapes what gets written, the
    # hook is the hard floor — LLMs are non-deterministic, so the floor stays.
    $settings
    | upsert hooks $hooks
    | upsert env $env_block
    | upsert outputStyle $GI_HOOK_STYLE
    | save --force $paths.settings

    # Seed the working-doc template, the output style, and the gi skills. Why
    # not clobber: once they exist they are the user's files — refreshing would
    # destroy their edits. --force overwrites the style and skills — they are
    # distributed text a module update should be able to refresh — but never
    # the working doc, which holds the user's work.
    for seed in (
        [
            [src dst overwrite];
            [$paths.template_src $doc_abs false]
        ] | append (gi-hook-refresh-seeds $paths | insert overwrite $force)
    ) {
        if $seed.overwrite or not ($seed.dst | path exists) {
            mkdir ($seed.dst | path dirname)
            cp $seed.src $seed.dst
        }
    }
    # The style is read once at session start, so it won't apply until /clear or
    # a new session; the hook takes effect immediately.
    print "gi-hook enabled. Run /clear or start a new session for the Canvas output style to load."
    # Same guard the hook enforces, surfaced at opt-in time — switching now
    # beats being blocked mid-session with commits already on the branch.
    let branch = gi-hook-branch $root
    if $branch in $GI_HOOK_PROTECTED_BRANCHES {
        print $"note: this repo is on ($branch) — gi commits belong on a work branch; the Stop hook will block turns until you switch."
    }
    let status = gi-hook-status --root $root
    # Surface drift at the moment the user is already touching gi-hook — status
    # carries the same list, but nobody polls it.
    if not $force and ($status.stale | is-not-empty) {
        print $"note: ($status.stale | length) seeded file\(s\) differ from the module — `gi-hook enable --force` refreshes them."
    }
    $status
}

# Remove our Stop hook, leaving any other hooks intact. No-op if absent.
def gi-hook-disable [
    --root: path # Repo root to remove from (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root) | path expand
    let path = (gi-hook-paths $root).settings
    if not ($path | path exists) { return (gi-hook-status --root $root) }

    # Emptied containers (hooks: {Stop: []}, env: {}) stay behind on purpose:
    # harmless in a gitignored machine-local file, and pruning them tripled
    # this body.
    gi-hook-open-settings $path
    | if ($in.hooks?.Stop? == null) { } else {
        update hooks.Stop { where {|e| not ($e | gi-hook-is-ours) } }
    }
    # Drop outputStyle only if it is still ours — never clobber a value the user
    # set themselves. The seeded style and working doc are left in place (user files).
    | if ($in.outputStyle? == $GI_HOOK_STYLE) { reject outputStyle } else { }
    | reject env?.GI_HOOK_DOC?
    | save --force $path
    gi-hook-status --root $root
}

# Report whether the hook is installed in this repo. Pipeline-friendly record.
def gi-hook-status [
    --root: path # Repo root to inspect (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root) | path expand
    let paths = gi-hook-paths $root
    let settings = gi-hook-open-settings $paths.settings
    let doc = gi-hook-doc $settings
    # Paths stay absolute and present whenever recorded. Shortening them
    # against PWD made the same field change spelling with where you stand,
    # and nulling missing seed files collapsed two states into one — a null
    # doc could mean "not recorded" or "recorded but deleted", which need
    # different user actions. Data here, display is the caller's business.
    {
        enabled: ($settings.hooks?.Stop? | default [] | any {|e| $e | gi-hook-is-ours })
        settings: $paths.settings
        doc: (if $doc != null { $root | path join $doc })
        style: $paths.style_dst
        skills: (gi-hook-skill-seeds $paths | get dst)
        stale: (gi-hook-stale $paths)
        output_style_set: ($settings.outputStyle? == $GI_HOOK_STYLE)
    }
}

# Stop-hook body. Reads the event JSON on stdin and returns either nothing
# (allow the turn to end) or the block-decision JSON string. `nu -c` renders
# the return value to stdout, which is the Stop hook's control channel; the
# command always exits 0, per the contract. Returning (not printing) keeps it
# unit-testable. The single `to json` lives here, next to the contract it
# serves — the rules deal in records only.
def gi-hook-check []: string -> any {
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
    let decision = try { $payload | gi-hook-check-rules } catch {|err|
        {decision: "block" reason: $"gi-hook check failed internally — fix this before continuing: ($err.msg)"}
    }
    if $decision != null { $decision | to json --raw }
}

# The actual gi rules, free to throw; gi-hook-check owns the exit-0 contract.
def gi-hook-check-rules []: record -> any {
    let payload = $in
    # Not the raw event cwd: the session's cwd may have drifted into a
    # subdirectory of wherever enable wrote the settings (and recorded doc).
    let root = gi-hook-settings-root ($payload.cwd? | default $env.PWD)

    # Branch guard, before the message rule: even a perfect `done` may not end
    # a turn on a protected branch — gi commits are internal working history,
    # and the sooner the agent hears it, the fewer commits there are to move.
    let branch = gi-hook-branch $root
    if $branch in $GI_HOOK_PROTECTED_BRANCHES {
        let reason = $"You are on `($branch)` — gi commits are internal working history and must not land here. Switch to a work branch \(`git switch -c <topic>`, moving any commits already made); it gets squash-merged into `($branch)` after finalization."
        return {decision: "block" reason: $reason}
    }

    let message = $payload.last_assistant_message? | default ""
    if (gi-hook-allowed $message) { return }

    # Name the exact working doc when enable recorded one. Why: the doc name is
    # timestamped or user-chosen, so a blocked agent can't guess it; naming it
    # makes the correction actionable without a discovery step. Read fresh from
    # settings at the event's cwd — not from $env, which Claude Code snapshots
    # at session start and would go stale on a mid-session re-enable.
    let doc = gi-hook-doc (gi-hook-open-settings (gi-hook-paths $root).settings)
    let doc = match ($doc | default "") {
        "" => "the working document"
        $p => $"`($p)`"
    }
    # The escape hatch is safe by construction: the blocked message is already
    # on the user's screen, and the stop_hook_active guard ends the turn on the
    # follow-up whatever it says — a stale hook can redirect one reply, never
    # trap the agent.
    let reason = $"Chat may carry only `done`/`noted` or a short pointer \(one line with a path/link). Move the full answer into ($doc) and commit it; leave only a pointer in chat. If this block looks like a misfire — stale hook, wrong doc, no gi work in this session — don't move anything: reply with one short line telling the user to read your previous message above in the chat and to check this hook \(`gi-hook status` / `disable`)."
    {decision: "block" reason: $reason}
}

# The allow-rule: what may stand alone in chat. True (allowed) when, after trim:
# empty; or `done`/`noted` (trailing punctuation ok); or a short pointer — one
# line, within the length budget, carrying a link signal (backtick, `→`, or a
# filename). Everything else (prose, long unanchored lines) is blocked.
# Why a budget env-var: "short pointer" is fuzzy; GI_HOOK_MAX_LEN makes the
# threshold tunable without editing the hook. Default is strict — prose fails.
export def gi-hook-allowed [message: string]: nothing -> bool {
    let text = $message | str trim
    if ($text | is-empty) { return true }
    if (($text | str lowercase | str replace -r '[.!…]+$' '') in ["done" "noted"]) { return true }

    let max = $env.GI_HOOK_MAX_LEN? | default 240 | into int
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
