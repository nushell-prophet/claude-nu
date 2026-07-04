use std assert
use std/testing *

# Import internals (helpers) and the public subcommands. The `gi-hook *`
# subcommands are exported from gi-hook.nu; pull them in unprefixed here.
use ../claude-nu/gi-hook.nu *

def temp-root []: nothing -> path {
    $nu.temp-dir | path join $"gi-hook-(random uuid)"
}

def settings-of [root: path]: nothing -> path {
    $root | path join ".claude" "settings.local.json"
}

# =============================================================================
# enable / disable / status — settings.local.json manipulation
# =============================================================================

@test
def "enable writes the Stop hook into an empty settings file" [] {
    let root = temp-root
    let status = gi-hook enable --root $root
    let settings = open (settings-of $root)
    rm -rf $root

    assert $status.enabled
    assert equal ($settings.hooks.Stop | length) 1
    let entry = $settings.hooks.Stop.0.hooks.0
    assert equal $entry.type "command"
    assert ($entry.command | str contains "gi-hook check")
}

@test
def "enable is idempotent — a second enable adds no duplicate" [] {
    let root = temp-root
    gi-hook enable --root $root | ignore
    gi-hook enable --root $root | ignore
    let settings = open (settings-of $root)
    rm -rf $root

    assert equal ($settings.hooks.Stop | length) 1
}

@test
def "enable preserves foreign hooks and other settings keys" [] {
    let root = temp-root
    mkdir ($root | path join ".claude")
    {
        permissions: { allow: ["Bash(ls:*)"] }
        hooks: { Stop: [ { hooks: [ { type: "command", command: "echo other" } ] } ] }
    } | save (settings-of $root)

    gi-hook enable --root $root | ignore
    let settings = open (settings-of $root)
    rm -rf $root

    # Our entry was appended next to the foreign one; nothing else touched.
    assert equal ($settings.hooks.Stop | length) 2
    assert equal $settings.permissions.allow ["Bash(ls:*)"]
    assert ($settings.hooks.Stop | any {|e| $e.hooks.0.command == "echo other" })
}

@test
def "disable removes only our entry and leaves foreign hooks" [] {
    let root = temp-root
    mkdir ($root | path join ".claude")
    {
        hooks: { Stop: [ { hooks: [ { type: "command", command: "echo other" } ] } ] }
    } | save (settings-of $root)
    gi-hook enable --root $root | ignore

    let status = gi-hook disable --root $root
    let settings = open (settings-of $root)
    rm -rf $root

    assert (not $status.enabled)
    assert equal ($settings.hooks.Stop | length) 1
    assert equal $settings.hooks.Stop.0.hooks.0.command "echo other"
}

@test
def "disable prunes emptied containers" [] {
    let root = temp-root
    gi-hook enable --root $root | ignore
    gi-hook disable --root $root | ignore
    let settings = open (settings-of $root)
    rm -rf $root

    # No orphan hooks/Stop keys left behind once our only entry is gone.
    assert equal $settings {}
}

@test
def "disable is a no-op when nothing is installed" [] {
    let root = temp-root
    let status = gi-hook disable --root $root
    let existed = settings-of $root | path exists
    rm -rf $root

    assert (not $status.enabled)
    assert (not $existed)
}

@test
def "enable seeds a timestamped working doc under gi and records it" [] {
    let root = temp-root
    let status = gi-hook enable --root $root
    let recorded = open (settings-of $root) | get env.GI_HOOK_DOC
    let deployed = $root | path join $recorded
    let exists = $deployed | path exists
    let body = if $exists { open --raw $deployed } else { "" }
    rm -rf $root

    assert ($status.doc != null)
    assert ($recorded | str starts-with "gi/canvas-")
    assert $exists
    assert ($body | is-not-empty)
}

@test
def "enable accepts a custom working-doc path" [] {
    let root = temp-root
    gi-hook enable notes/plan.md --root $root | ignore
    let recorded = open (settings-of $root) | get env.GI_HOOK_DOC
    let exists = $root | path join "notes" "plan.md" | path exists
    rm -rf $root

    assert equal $recorded "notes/plan.md"
    assert $exists
}

@test
def "re-enable keeps the recorded doc unless a new one is given" [] {
    let root = temp-root
    gi-hook enable --root $root | ignore
    let first = open (settings-of $root) | get env.GI_HOOK_DOC
    gi-hook enable --root $root | ignore
    let second = open (settings-of $root) | get env.GI_HOOK_DOC
    gi-hook enable other.md --root $root | ignore
    let third = open (settings-of $root) | get env.GI_HOOK_DOC
    rm -rf $root

    assert equal $first $second
    assert equal $third "other.md"
}

@test
def "enable does not clobber an existing working doc" [] {
    let root = temp-root
    mkdir ($root | path join "gi")
    let deployed = $root | path join "gi" "doc.md"
    "my edited working doc" | save $deployed
    gi-hook enable gi/doc.md --root $root | ignore
    let body = open --raw $deployed
    rm -rf $root

    assert equal $body "my edited working doc"
}

@test
def "a doc path with a non-enable action errors" [] {
    let root = temp-root
    let out = try { gi-hook status some.md --root $root; null } catch {|e| $e.msg }
    rm -rf $root

    assert ($out != null)
}

@test
def "disable removes the recorded doc and preserves foreign env vars" [] {
    let root = temp-root
    mkdir ($root | path join ".claude")
    { env: { OTHER: "kept" } } | save (settings-of $root)
    gi-hook enable --root $root | ignore
    gi-hook disable --root $root | ignore
    let settings = open (settings-of $root)
    rm -rf $root

    assert equal $settings.env { OTHER: "kept" }
}

@test
def "enable distributes the output style and sets outputStyle" [] {
    let root = temp-root
    let status = gi-hook enable --root $root
    let style = $root | path join ".claude" "output-styles" "canvas.md"
    let exists = $style | path exists
    let body = if $exists { open --raw $style } else { "" }
    let settings = open (settings-of $root)
    rm -rf $root

    assert ($status.style != null)
    assert $status.output_style_set
    assert $exists
    assert ($body | str contains "name: Canvas")
    assert equal $settings.outputStyle "Canvas"
}

@test
def "enable does not clobber an edited style" [] {
    let root = temp-root
    let style = $root | path join ".claude" "output-styles" "canvas.md"
    mkdir ($style | path dirname)
    "my edited style" | save $style
    gi-hook enable --root $root | ignore
    let body = open --raw $style
    rm -rf $root

    assert equal $body "my edited style"
}

@test
def "disable drops our outputStyle but keeps a foreign one" [] {
    let root = temp-root
    gi-hook enable --root $root | ignore
    # User switched to their own style while canvas mode was on; disable must
    # leave it, removing only the value we set.
    open (settings-of $root) | upsert outputStyle "Explanatory" | save --force (settings-of $root)
    gi-hook disable --root $root | ignore
    let settings = open (settings-of $root)
    rm -rf $root

    assert equal $settings.outputStyle "Explanatory"
}

@test
def "status reflects enabled and disabled state" [] {
    let root = temp-root
    let before = gi-hook status --root $root
    gi-hook enable --root $root | ignore
    let after = gi-hook status --root $root
    rm -rf $root

    assert (not $before.enabled)
    assert $after.enabled
    # Presence-by-value: seed fields are null before enable, paths after.
    assert equal $before.doc null
    assert ($after.doc != null)
}

# =============================================================================
# check — the Stop hook decision (contract)
# =============================================================================

def block-decision [payload: record]: nothing -> any {
    # Default cwd to a non-repo dir so the branch guard sees the payload's
    # state, not whatever branch the test runner's own repo happens to be on.
    {cwd: $nu.temp-dir} | merge $payload | to json | gi-hook check
}

@test
def "check allows when stop_hook_active is true - loop guard" [] {
    let out = block-decision { stop_hook_active: true, last_assistant_message: "long prose that would otherwise block here for sure" }
    assert equal $out null
}

@test
def "check allows done and noted" [] {
    assert equal (block-decision { last_assistant_message: "done" }) null
    assert equal (block-decision { last_assistant_message: "Noted." }) null
}

@test
def "check allows a short pointer carrying a path" [] {
    let out = block-decision { last_assistant_message: "done — see `commands.nu`" }
    assert equal $out null
}

@test
def "check blocks multiline prose" [] {
    let out = block-decision { last_assistant_message: "First I changed the parser.\nThen I updated the tests.\nHere is why it matters." }
    assert equal ($out | from json | get decision) "block"
}

@test
def "check blocks a long single line with no link signal" [] {
    let out = block-decision { last_assistant_message: "this is a single line but it is quite long and carries no link signal anywhere in it at all friend" }
    assert equal ($out | from json | get decision) "block"
}

@test
def "check treats an empty message as allowed" [] {
    assert equal (block-decision { last_assistant_message: "" }) null
}

@test
def "check names the recorded doc in the block reason" [] {
    let root = temp-root
    gi-hook enable gi/plan.md --root $root | ignore
    let prose = "Long prose without any link signal that must be blocked by the rule"
    let named = block-decision { last_assistant_message: $prose, cwd: $root } | from json | get reason
    rm -rf $root

    assert ($named | str contains "`gi/plan.md`")
}

@test
def "check blocks a protected branch even when the message is allowed" [] {
    let root = temp-root
    git init -qb master $root
    let out = block-decision { last_assistant_message: "done", cwd: $root }
    rm -rf $root

    let decision = $out | from json
    assert equal $decision.decision "block"
    assert ($decision.reason | str contains "`master`")
}

@test
def "check passes an allowed message on a work branch" [] {
    let root = temp-root
    git init -qb canvas-work $root
    let out = block-decision { last_assistant_message: "done", cwd: $root }
    rm -rf $root

    assert equal $out null
}

@test
def "check falls back to generic wording when no doc is recorded" [] {
    let root = temp-root
    mkdir $root
    let prose = "Long prose without any link signal that must be blocked by the rule"
    let generic = block-decision { last_assistant_message: $prose, cwd: $root } | from json | get reason
    rm -rf $root

    assert ($generic | str contains "the working document")
}

# =============================================================================
# gi-hook-allowed — the allow-rule, tested directly
# =============================================================================

@test
def "allow-rule passes empty, done, noted, and short pointers" [] {
    assert (gi-hook-allowed "")
    assert (gi-hook-allowed "done")
    assert (gi-hook-allowed "DONE!")
    assert (gi-hook-allowed "noted")
    assert (gi-hook-allowed "moved to `docs/plan.md`")
    assert (gi-hook-allowed "see commands.nu:1180")
    assert (gi-hook-allowed "next → tests/test_gi_hook.nu")
}

@test
def "allow-rule blocks prose and unanchored lines" [] {
    assert (not (gi-hook-allowed "Here is a plain sentence with no link that should not be allowed in chat"))
    assert (not (gi-hook-allowed "line one\nline two"))
}

@test
def "allow-rule budget is tunable via GI_HOOK_MAX_LEN" [] {
    with-env { GI_HOOK_MAX_LEN: "10" } {
        assert (not (gi-hook-allowed "short `f.nu`")) # 12 chars > 10 → blocked
    }
    with-env { GI_HOOK_MAX_LEN: "500" } {
        assert (gi-hook-allowed "short `f.nu`")
    }
}
