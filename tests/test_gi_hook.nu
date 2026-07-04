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
def "enable seeds the gi working-doc template" [] {
    let root = temp-root
    let status = gi-hook enable --root $root
    let deployed = $root | path join "gi" "canvas-header.md"
    let exists = $deployed | path exists
    let body = if $exists { open --raw $deployed } else { "" }
    rm -rf $root

    assert $status.template_present
    assert $exists
    assert ($body | is-not-empty)
}

@test
def "enable does not clobber an edited template" [] {
    let root = temp-root
    mkdir ($root | path join "gi")
    let deployed = $root | path join "gi" "canvas-header.md"
    "my edited working doc" | save $deployed
    gi-hook enable --root $root | ignore
    let body = open --raw $deployed
    rm -rf $root

    assert equal $body "my edited working doc"
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

    assert $status.style_present
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
    assert ($after.command | str contains "gi-hook check")
}

# =============================================================================
# check — the Stop hook decision (contract)
# =============================================================================

def block-decision [payload: record]: nothing -> any {
    $payload | to json | gi-hook check
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
