use std/assert
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
def "re-enable refreshes a stale hook command" [] {
    let root = temp-root
    mkdir ($root | path join ".claude")
    # Our marker, but a command recorded from a since-moved checkout.
    {
        hooks: { Stop: [ { hooks: [ { type: "command", command: "nu -c 'use /old/checkout; gi-hook check'" } ] } ] }
    } | save (settings-of $root)
    gi-hook enable --root $root | ignore
    let settings = open (settings-of $root)
    rm -rf $root

    assert equal ($settings.hooks.Stop | length) 1
    assert ($settings.hooks.Stop.0.hooks.0.command | str contains "--stdin")
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
def "disable removes every value gi-hook set" [] {
    let root = temp-root
    gi-hook enable --root $root | ignore
    gi-hook disable --root $root | ignore
    let settings = open (settings-of $root)
    rm -rf $root

    # Emptied containers stay behind (harmless in a gitignored local file);
    # what matters is that no gi-hook entry, doc, or style survives.
    assert equal $settings.hooks.Stop []
    assert equal $settings.env {}
    assert equal $settings.outputStyle? null
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
def "enable seeds the gi skills into .claude/skills" [] {
    let root = temp-root
    let status = gi-hook enable --root $root
    let all_exist = $status.skills | all {|p| $p | path exists }
    let names = $status.skills | each {|p| $p | path dirname | path basename } | sort
    rm -rf $root

    assert $all_exist
    assert equal $names ["git-intent" "git-intent-distill" "git-intent-squash-archive"]
}

@test
def "enable does not clobber an edited skill" [] {
    let root = temp-root
    let skill = $root | path join ".claude" "skills" "git-intent" "SKILL.md"
    mkdir ($skill | path dirname)
    "my edited skill" | save $skill
    gi-hook enable --root $root | ignore
    let body = open --raw $skill
    rm -rf $root

    assert equal $body "my edited skill"
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
def "enable --force refreshes an edited style and skill" [] {
    let root = temp-root
    gi-hook enable --root $root | ignore
    let style = $root | path join ".claude" "output-styles" "canvas.md"
    let skill = $root | path join ".claude" "skills" "git-intent" "SKILL.md"
    "edited style" | save --force $style
    "edited skill" | save --force $skill
    gi-hook enable --root $root --force | ignore
    let style_body = open --raw $style
    let skill_body = open --raw $skill
    rm -rf $root

    assert ($style_body | str contains "name: Canvas")
    assert ($skill_body | str contains "name: git-intent")
}

@test
def "status reports seeds differing from the module as stale" [] {
    let root = temp-root
    gi-hook enable --root $root | ignore
    let fresh = gi-hook status --root $root | get stale
    "user edit" | save --force ($root | path join ".claude" "skills" "git-intent" "SKILL.md")
    let edited = gi-hook status --root $root | get stale
    gi-hook enable --root $root --force | ignore
    let refreshed = gi-hook status --root $root | get stale
    rm -rf $root

    assert equal $fresh []
    assert equal ($edited | each {|p| $p | path dirname | path basename }) ["git-intent"]
    assert equal $refreshed []
}

@test
def "enable --force never overwrites the working doc" [] {
    let root = temp-root
    gi-hook enable gi/doc.md --root $root | ignore
    let doc = $root | path join "gi" "doc.md"
    "my work" | save --force $doc
    gi-hook enable --root $root --force | ignore
    let body = open --raw $doc
    rm -rf $root

    assert equal $body "my work"
}

# Not named "--force ..." because: nutest interpolates test names into a
# block, where a leading -- parses as a flag and kills the whole suite.
@test
def "a force flag with a non-enable action errors" [] {
    let out = try { gi-hook status --force; null } catch {|e| $e.msg }
    assert ($out != null)
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
def "enable stores an absolute doc arriving through a symlink as root-relative" [] {
    let root = temp-root
    mkdir ($root | path join "gi")
    let link = $"($root)-link"
    ^ln -s $root $link
    gi-hook enable ($link | path join "gi" "plan.md") --root $root | ignore
    let recorded = open (settings-of $root) | get env.GI_HOOK_DOC
    rm -rf $root $link

    assert equal $recorded "gi/plan.md"
}

@test
def "status returns absolute paths regardless of cwd" [] {
    let root = temp-root
    gi-hook enable --root $root | ignore
    let expected = settings-of ($root | path expand)
    let orig = $env.PWD
    cd $root
    let status = gi-hook status --root $root
    cd $orig
    rm -rf $root

    # Data, not display: paths never shorten against PWD, so a consumer gets
    # the same value wherever status is called from.
    assert equal $status.settings $expected
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
    # doc is null until enable records one in settings.
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
def "check treats a non-object payload as empty, inside the contract" [] {
    # cd away from the test runner's repo: a {} payload falls back to PWD.
    let orig = $env.PWD
    cd $nu.temp-dir
    for raw in ['"hi"' '123' 'null' '[1, 2]'] {
        assert equal ($raw | gi-hook check) null
    }
    cd $orig
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

# The Stop-hook contract: check may never throw (exit 1 reads as a
# non-blocking error to Claude Code and enforcement silently vanishes) —
# internal failures must surface as a block decision instead.
@test
def "check converts internal errors into a block, not a crash" [] {
    let prose = "Long prose without any link signal that must be blocked by the rule"

    let broken = temp-root
    mkdir ($broken | path join ".claude")
    "{ broken json" | save ($broken | path join ".claude" "settings.local.json")
    let from_bad_json = block-decision { last_assistant_message: $prose, cwd: $broken }
    rm -rf $broken

    let misshapen = temp-root
    mkdir ($misshapen | path join ".claude")
    { env: "oops" } | save ($misshapen | path join ".claude" "settings.local.json")
    let from_bad_shape = block-decision { last_assistant_message: $prose, cwd: $misshapen }
    rm -rf $misshapen

    let from_bad_knob = with-env { GI_HOOK_MAX_LEN: "abc" } {
        block-decision { last_assistant_message: $prose }
    }

    for out in [$from_bad_json $from_bad_shape $from_bad_knob] {
        let decision = $out | from json
        assert equal $decision.decision "block"
        assert ($decision.reason | str contains "failed internally")
    }
}

@test
def "check finds the settings from a subdirectory cwd" [] {
    let root = temp-root
    git init -qb canvas-work $root
    mkdir ($root | path join "sub")
    gi-hook enable gi/plan.md --root $root | ignore
    let prose = "Long prose without any link signal that must be blocked by the rule"
    let out = block-decision { last_assistant_message: $prose, cwd: ($root | path join "sub") }
    rm -rf $root

    assert ($out | from json | get reason | str contains "`gi/plan.md`")
}

@test
def "check honors settings enabled at a monorepo subproject" [] {
    let root = temp-root
    let subproj = $root | path join "tools" "subproj"
    git init -qb canvas-work $root
    mkdir ($subproj | path join "deeper")
    gi-hook enable gi/plan.md --root $subproj | ignore
    let prose = "Long prose without any link signal that must be blocked by the rule"
    let out = block-decision { last_assistant_message: $prose, cwd: ($subproj | path join "deeper") }
    rm -rf $root

    # The walk up from cwd stops at the subproject's settings, not the toplevel.
    assert ($out | from json | get reason | str contains "`gi/plan.md`")
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
    # Abbreviations and glued sentences are not filename signals.
    assert (not (gi-hook-allowed "short prose with e.g an aside"))
    assert (not (gi-hook-allowed "First thought ends.Next one starts"))
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
