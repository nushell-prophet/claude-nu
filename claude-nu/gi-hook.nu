# gi-hook — a per-repo Stop hook that keeps the chat terse (gi protocol)
#
# The gi protocol moves all "what/why" into git: the diff and the commit body
# carry the record, the chat carries almost nothing. That rule rests on prose
# alone and fights the model's training — the agent drifts back to long chat
# answers. This installs a structural barrier instead of self-control: a
# Claude Code Stop hook that blocks the turn when the final chat message is
# more than `done`/`noted` or a short pointer, and tells the agent to move the
# answer into a document. Opt-in and per-repo, so the classic mode is untouched.

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

# Root of the current repo (git top-level), falling back to PWD outside a repo.
def gi-hook-repo-root []: nothing -> path {
    let top = do { ^git rev-parse --show-toplevel } | complete
    if $top.exit_code == 0 { $top.stdout | str trim } else { $env.PWD | path expand }
}

# Path to the per-repo, per-machine settings file the hook lives in. Why this
# file: it is already gitignored by Claude Code, so the hook stays local — it
# never reaches another checkout or the classic mode.
def gi-hook-settings-path [root: path]: nothing -> path {
    $root | path join ".claude" "settings.local.json"
}

# The shell command Claude Code runs for the Stop event. Single-quote the `-c`
# body so the outer shell does not expand `$in`; `--stdin` feeds the event JSON
# to nushell as `$in`. The absolute module path is required — relative paths are
# not resolved at hook time. `path self` anchors it to this file's directory.
def gi-hook-command []: nothing -> string {
    $"nu --stdin -c 'use \"($GI_HOOK_MODULE_DIR)\"; $in | claude-nu gi-hook check'"
}

# The Stop hook entry as stored under hooks.Stop[].
def gi-hook-entry [command: string]: nothing -> record {
    { hooks: [ { type: "command", command: $command } ] }
}

# The gi working-doc template that ships inside the module (so it vendors with
# it) and the place `enable` drops it in a target repo. Why a repo-local
# `gi-md-src/`: the gi protocol keeps the live working doc under version
# control, so it sits next to the code it drives, not in a dotfile.
def gi-hook-template-src []: nothing -> path {
    $GI_HOOK_MODULE_DIR | path join "gi-md-src" "canvas-header.md"
}

def gi-hook-template-dst [root: path]: nothing -> path {
    $root | path join "gi-md-src" "canvas-header.md"
}

# The output style gi-hook distributes: the template that ships inside the module
# and the project-level path it lands at. Why distribute a local copy: gi-hook is
# vendored on its own, so it must carry the style itself rather than depend on a
# Claude plugin being installed — `enable` drops it as a per-repo project style.
def gi-hook-style-src []: nothing -> path {
    $GI_HOOK_MODULE_DIR | path join "gi-md-src" "canvas-output-style.md"
}

def gi-hook-style-dst [root: path]: nothing -> path {
    $root | path join ".claude" "output-styles" "canvas.md"
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
        [enable  "install the Stop hook in this repo"]
        [disable "remove it (leaves any other hooks intact)"]
        [status  "show whether it is installed"]
        [check   "hook body — reads the Stop event JSON on stdin"]
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
    --root: path # Repo root (default: git top-level); ignored by check
]: any -> any {
    let event = $in # check reads the Stop event here; the others ignore it
    match $action {
        null | "status" => (gi-hook-status --root $root)
        "enable" => (gi-hook-enable --root $root)
        "disable" => (gi-hook-disable --root $root)
        "check" => ($event | gi-hook-check)
        _ => {
            error make {
                msg: $"unknown gi-hook action: ($action)"
                label: { text: "expected enable, disable, status, or check", span: (metadata $action).span }
            }
        }
    }
}

# Install the Stop hook into this repo's .claude/settings.local.json.
# Idempotent: a second enable does not add a duplicate.
def gi-hook-enable [
    --root: path # Repo root to install into (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root)
    let path = gi-hook-settings-path $root
    let command = gi-hook-command
    let settings = gi-hook-open-settings $path

    let stop = $settings.hooks?.Stop? | default []
    let already = $stop | any {|e| $e | gi-hook-is-ours }
    let stop = if $already { $stop } else { $stop | append (gi-hook-entry $command) }

    let hooks = $settings.hooks? | default {} | upsert Stop $stop
    mkdir ($path | path dirname)
    # Set outputStyle alongside the hook so the proactive style and the reactive
    # hook turn on together. Why both: the style shapes what gets written, the
    # hook is the hard floor — LLMs are non-deterministic, so the floor stays.
    $settings | upsert hooks $hooks | upsert outputStyle $GI_HOOK_STYLE | save --force $path

    # Seed the gi working-doc template. Why not clobber: once it exists it is
    # the user's live doc — refreshing it would destroy their edits.
    let template = gi-hook-template-dst $root
    if not ($template | path exists) {
        mkdir ($template | path dirname)
        cp (gi-hook-template-src) $template
    }
    # Distribute the output style as a per-repo project style. Same no-clobber
    # rule: the user may have edited their local copy.
    let style = gi-hook-style-dst $root
    if not ($style | path exists) {
        mkdir ($style | path dirname)
        cp (gi-hook-style-src) $style
    }
    # The style is read once at session start, so it won't apply until /clear or
    # a new session; the hook takes effect immediately.
    print "gi-hook enabled. Run /clear or start a new session for the Canvas output style to load."
    gi-hook-status --root $root
}

# Remove our Stop hook, leaving any other hooks intact. No-op if absent.
def gi-hook-disable [
    --root: path # Repo root to remove from (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root)
    let path = gi-hook-settings-path $root
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
    $settings | save --force $path
    gi-hook-status --root $root
}

# Report whether the hook is installed in this repo. Pipeline-friendly record.
def gi-hook-status [
    --root: path # Repo root to inspect (default: git top-level)
]: nothing -> record {
    let root = $root | default (gi-hook-repo-root)
    let path = gi-hook-settings-path $root
    let settings = gi-hook-open-settings $path
    let stop = $settings.hooks?.Stop? | default []
    let template = gi-hook-template-dst $root
    let style = gi-hook-style-dst $root
    {
        enabled: ($stop | any {|e| $e | gi-hook-is-ours })
        settings_path: $path
        command: (gi-hook-command)
        template_path: $template
        template_present: ($template | path exists)
        style_path: $style
        style_present: ($style | path exists)
        output_style_set: ($settings.outputStyle? == $GI_HOOK_STYLE)
    }
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

    let message = $payload.last_assistant_message? | default ""
    if (gi-hook-allowed $message) { return }

    let reason = "Chat may carry only `done`/`noted` or a short pointer (one line with a path/link). Move the full answer into the working document and commit it; leave only a pointer in chat."
    { decision: "block", reason: $reason } | to json --raw
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
