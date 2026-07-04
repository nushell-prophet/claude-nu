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

# Root of the current repo (git top-level), falling back to PWD outside a repo.
def gi-hook-repo-root []: nothing -> path {
    let top = do { ^git rev-parse --show-toplevel } | complete
    if $top.exit_code == 0 { $top.stdout | str trim } else { $env.PWD | path expand }
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
def gi-hook-paths [root: path]: nothing -> record {
    {
        settings: ($root | path join ".claude" "settings.local.json")
        template_src: ($GI_HOOK_MODULE_DIR | path join "gi-md-src" "canvas-header.md")
        style_src: ($GI_HOOK_MODULE_DIR | path join "gi-md-src" "canvas-output-style.md")
        style_dst: ($root | path join ".claude" "output-styles" "canvas.md")
    }
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
]: any -> any {
    let event = $in # check reads the Stop event here; the others ignore it
    if $doc != null and $action != "enable" {
        error make {
            msg: "a working-doc path only makes sense with enable"
            label: {text: "drop this, or use: gi-hook enable <doc>" span: (metadata $doc).span}
        }
    }
    match $action {
        null | "status" => (gi-hook-status --root $root)
        "enable" => (gi-hook-enable --root $root --doc $doc)
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
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root)
    let paths = gi-hook-paths $root
    let settings = gi-hook-open-settings $paths.settings

    # Resolve the working doc: explicit arg wins; else keep the recorded one so
    # re-enable is idempotent; else mint a timestamped default. Stored
    # root-relative when under root — the hook runs with cwd at the project, so
    # the short form works in the block message and survives a checkout move.
    let doc = $doc | default (gi-hook-doc $settings) | default $"gi/canvas-(date now | format date '%J_%Q').md"
    let doc_abs = $root | path join $doc
    let doc = if ($doc_abs | str starts-with $"($root)/") { $doc_abs | path relative-to $root } else { $doc_abs }

    let stop = $settings.hooks?.Stop? | default []
    let already = $stop | any {|e| $e | gi-hook-is-ours }
    let stop = if $already { $stop } else {
        $stop | append {hooks: [{type: "command" command: $GI_HOOK_COMMAND}]}
    }

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

    # Seed the working-doc template and the output style. Why not clobber: once
    # they exist they are the user's files — refreshing would destroy their edits.
    for seed in [
        [src dst];
        [$paths.template_src $doc_abs]
        [$paths.style_src $paths.style_dst]
    ] {
        if not ($seed.dst | path exists) {
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
    gi-hook-status --root $root
}

# Remove our Stop hook, leaving any other hooks intact. No-op if absent.
def gi-hook-disable [
    --root: path # Repo root to remove from (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root)
    let path = (gi-hook-paths $root).settings
    if not ($path | path exists) { return (gi-hook-status --root $root) }

    let settings = gi-hook-open-settings $path
    let stop = $settings.hooks?.Stop? | default [] | where {|e| not ($e | gi-hook-is-ours) }
    # Prune emptied containers so disable leaves no orphan keys behind.
    let hooks = $settings.hooks? | default {}
    let hooks = if ($stop | is-empty) { $hooks | reject Stop? } else { $hooks | upsert Stop $stop }
    let settings = if ($hooks | is-empty) { $settings | reject hooks? } else { $settings | upsert hooks $hooks }
    # Drop outputStyle only if it is still ours — never clobber a value the user
    # set themselves. The seeded style and working doc are left in place (user files).
    let settings = if ($settings.outputStyle? == $GI_HOOK_STYLE) { $settings | reject outputStyle? } else { $settings }
    # Same for env: remove only our GI_HOOK_DOC key, prune env if that empties it.
    let env_block = $settings.env? | default {} | reject GI_HOOK_DOC?
    let settings = if ($env_block | is-empty) { $settings | reject env? } else { $settings | upsert env $env_block }
    $settings | save --force $path
    gi-hook-status --root $root
}

# Report whether the hook is installed in this repo. Pipeline-friendly record.
def gi-hook-status [
    --root: path # Repo root to inspect (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root)
    let paths = gi-hook-paths $root
    let settings = gi-hook-open-settings $paths.settings
    let doc = gi-hook-doc $settings
    {
        enabled: ($settings.hooks?.Stop? | default [] | any {|e| $e | gi-hook-is-ours })
        settings: $paths.settings
        doc: (if $doc != null { $root | path join $doc })
        style: $paths.style_dst
        output_style_set: ($settings.outputStyle? == $GI_HOOK_STYLE)
    }
    # Display-only: paths under PWD show relative; operational paths stay
    # absolute. Not `path relative-to` under try because: the error path costs
    # ~10x the guard and error-as-control-flow reads worse than a plain check.
    # The guard needs the trailing slash: starts-with compares strings while
    # relative-to compares path components — without it a sibling dir like
    # /a/bc passes the /a/b guard and relative-to puts a CantConvert in the cell.
    | update cells --columns [settings doc style] {
        if $in != null and ($in | str starts-with $"($env.PWD)/") { path relative-to $env.PWD } else { }
    }
    # Seed fields carry presence by value: the path when the file exists, null
    # (an empty cell) when it does not. Runs after the shortening on purpose —
    # a relative path resolves against PWD, exactly what the strip took off.
    | update cells --columns [doc style] {|p| if $p != null and ($p | path exists) { $p } }
}

# Stop-hook body. Reads the event JSON on stdin and returns either nothing
# (allow the turn to end) or the block-decision JSON string. `nu -c` renders
# the return value to stdout, which is the Stop hook's control channel; the
# command always exits 0, per the contract. Returning (not printing) keeps it
# unit-testable.
def gi-hook-check []: string -> any {
    let payload = try { $in | default "" | from json } catch { {} }
    # Already continuing from a prior block — let it end to avoid a loop.
    if ($payload.stop_hook_active? | default false) { return }

    let root = $payload.cwd? | default $env.PWD

    # Branch guard, before the message rule: even a perfect `done` may not end
    # a turn on a protected branch — gi commits are internal working history,
    # and the sooner the agent hears it, the fewer commits there are to move.
    let branch = gi-hook-branch $root
    if $branch in $GI_HOOK_PROTECTED_BRANCHES {
        let reason = $"You are on `($branch)` — gi commits are internal working history and must not land here. Switch to a work branch \(`git switch -c <topic>`, moving any commits already made); it gets squash-merged into `($branch)` after finalization."
        return ({decision: "block" reason: $reason} | to json --raw)
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
    let reason = $"Chat may carry only `done`/`noted` or a short pointer \(one line with a path/link). Move the full answer into ($doc) and commit it; leave only a pointer in chat."
    {decision: "block" reason: $reason} | to json --raw
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
    if (($text | str downcase | str replace -r '[.!…]+$' '') in ["done" "noted"]) { return true }

    let max = $env.GI_HOOK_MAX_LEN? | default 120 | into int
    let single_line = not ($text | str contains "\n")
    let within = ($text | str length) <= $max
    let has_signal = ($text =~ '`') or ($text =~ '→') or ($text =~ '[\w./-]+\.\w+')
    $single_line and $within and $has_signal
}
