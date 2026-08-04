use std/assert
use std/testing *

# Import internals (helpers) and the public command. `use gi.nu *` yields the
# `gi` command (main) plus the exported helpers, unprefixed.
use ../claude-nu/gi.nu *

def temp-root []: nothing -> path {
    $nu.temp-dir | path join $"gi-(random uuid)"
}

def settings-of [root: path]: nothing -> path {
    $root | path join ".claude" "settings.local.json"
}

# A directory holding a `claude` that records its arguments instead of starting
# a session, for the tests that run a launch to the end. Returns the directory,
# to be prepended to PATH for that call only.
# The `which` assertion is the guard that matters: PATH lookup silently skips a
# file it cannot execute, so a temp dir mounted noexec (or a chmod that did not
# take) would hand the launch to the REAL claude, which then blocks on a TTY —
# a hang, not a failure.
def stub-claude [root: path]: nothing -> path {
    let dir = $root | path join "stub-bin"
    mkdir $dir
    let bin = $dir | path join "claude"
    $"#!/bin/sh\necho \"$@\" > ($root | path join 'claude-args')\n" | save --force $bin
    ^chmod +x $bin
    with-env {PATH: ([$dir] | append $env.PATH)} {
        assert equal (which claude | get path.0? ) $bin "the stub claude is not the one PATH resolves"
    }
    $dir
}

# An unbound canvas, the way `gi open` leaves one before a session is stamped
# in. enable does not make canvases, so tests that need one write it directly.
def plain-canvas [root: path, rel: string]: nothing -> path {
    let doc = $root | path join $rel
    mkdir ($doc | path dirname)
    "# Working area\n" | save --force $doc
    $doc
}

# =============================================================================
# enable — seeding only; nothing is turned on and nothing is recorded
# =============================================================================

@test
def "enable writes no settings file" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let wrote_settings = settings-of $root | path exists
    rm -rf $root

    # The whole point of the redesign: activation travels with `gi open`, so a
    # seeded repo carries no outputStyle, no hook, and no env for other sessions.
    assert (not $wrote_settings)
}

@test
def "enable leaves a foreign settings file untouched" [] {
    let root = temp-root
    mkdir ($root | path join ".claude")
    let before = { permissions: { allow: ["Bash(ls:*)"] } }
    $before | save (settings-of $root)
    gi enable --root $root | ignore
    let after = open (settings-of $root)
    rm -rf $root

    assert equal $after $before
}

@test
def "enable makes no canvas" [] {
    let root = temp-root
    let status = gi enable --root $root
    let gi_dir = $root | path join "gi" | path exists
    rm -rf $root

    # Canvases belong to the two verbs that make one: `gi open <doc>` creates
    # and binds in the same breath, `gi import` writes one from a session. A
    # canvas seeded here would be an unbound file nobody asked for — enable
    # does not even carry a `doc` field to report.
    assert ("doc" not-in ($status | columns))
    assert (not $gi_dir)
}

@test
def "enable distributes the output style" [] {
    let root = temp-root
    let status = gi enable --root $root
    let exists = $status.style | path exists
    let body = if $exists { open --raw $status.style } else { "" }
    rm -rf $root

    assert $exists
    assert ($body | str contains "name: Canvas")
}

@test
def "enable seeds the gi skills into .claude/skills" [] {
    let root = temp-root
    let status = gi enable --root $root
    let all_exist = $status.skills | all {|p| $p | path exists }
    let names = $status.skills | each {|p| $p | path dirname | path basename } | sort
    rm -rf $root

    assert $all_exist
    assert equal $names ["gi-canvas" "git-intent" "git-intent-distill" "git-intent-readback" "git-intent-squash-archive"]
}

@test
def "enable does not clobber an edited skill" [] {
    let root = temp-root
    let skill = $root | path join ".claude" "skills" "git-intent" "SKILL.md"
    mkdir ($skill | path dirname)
    "my edited skill" | save $skill
    gi enable --root $root | ignore
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
    gi enable --root $root | ignore
    let body = open --raw $style
    rm -rf $root

    assert equal $body "my edited style"
}

@test
def "enable --force refreshes an edited style and skill" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let style = $root | path join ".claude" "output-styles" "canvas.md"
    let skill = $root | path join ".claude" "skills" "git-intent" "SKILL.md"
    "edited style" | save --force $style
    "edited skill" | save --force $skill
    gi enable --root $root --force | ignore
    let style_body = open --raw $style
    let skill_body = open --raw $skill
    rm -rf $root

    assert ($style_body | str contains "name: Canvas")
    assert ($skill_body | str contains "name: git-intent")
}

@test
def "enable --force never touches a canvas" [] {
    let root = temp-root
    let doc = plain-canvas $root "gi/doc.md"
    "my work" | save --force $doc
    gi enable --root $root --force | ignore
    let body = open --raw $doc
    rm -rf $root

    # --force refreshes distributed text (style, skills). A canvas is the
    # user's work and is not distributed text — enable never writes one.
    assert equal $body "my work"
}

@test
def "enable writes an ignore file naming every seed, and not itself" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let lines = open --raw ($root | path join ".claude" ".gitignore") | lines | where $it !~ '^#'
    rm -rf $root

    # Exact paths only: gi seeds into .claude/ but does not own it, and a `*` or
    # a bare `skills/` would hide a skill the user wrote by hand.
    assert equal ($lines | where $it =~ '\*' | length) 0
    assert ("output-styles/canvas.md" in $lines)
    assert ("skills/gi-canvas/SKILL.md" in $lines)
    # Not itself: that one visible file is what keeps `.claude/` in `git status`
    # as a single line instead of vanishing.
    assert equal ($lines | where $it =~ 'gitignore' | length) 0
}

@test
def "the ignore block is regenerated and lines outside it are kept" [] {
    let root = temp-root
    mkdir ($root | path join ".claude")
    "settings.local.json\n" | save --force ($root | path join ".claude" ".gitignore")
    gi enable --root $root | ignore
    let first = open --raw ($root | path join ".claude" ".gitignore")
    # Somebody else's line arriving after gi's block, and a stale entry inside it.
    $first | str replace "output-styles/canvas.md" "gone/from/the/module.md" | $"($in)mine/\n"
    | save --force ($root | path join ".claude" ".gitignore")
    gi enable --root $root | ignore
    let second = open --raw ($root | path join ".claude" ".gitignore")
    rm -rf $root

    # gi rewrites what is between its markers — that is what answers the "second
    # copy of the seed list" objection, since a skill added to gi-md-src cannot
    # be left unignored.
    assert ($second | str contains "output-styles/canvas.md")
    assert (not ($second | str contains "gone/from/the/module.md"))
    # And touches nothing outside them: `.claude/` is a shared folder, so a line
    # gi did not write is not gi's to delete.
    assert ($second | str contains "settings.local.json")
    assert ($second | str contains "mine/")
    # One block, not one per run.
    assert equal ($second | lines | where $it =~ '^# end gi seeds$' | length) 1
}

@test
def "an unclosed gi block is an error, not a second block" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let mangled = open --raw ($root | path join ".claude" ".gitignore")
    | lines | where $it !~ '^# end gi seeds$' | str join "\n"
    $mangled | save --force ($root | path join ".claude" ".gitignore")
    let out = try { gi enable --root $root | ignore; "" } catch {|e| $e.msg }
    rm -rf $root

    # Without the closing line gi cannot tell where its own entries stop, and
    # guessing would either swallow the rest of the file or stack blocks.
    assert ($out | str contains "no closing line")
}

@test
def "enable --no-gitignore leaves the seeds visible to git" [] {
    let root = temp-root
    gi enable --root $root --no-gitignore | ignore
    let wrote = $root | path join ".claude" ".gitignore" | path exists
    let seeded = $root | path join ".claude" "output-styles" "canvas.md" | path exists
    rm -rf $root

    # For the repo that wants the seeds committed so a teammate gets gi on
    # clone. Only this verb can decline: `gi open` always writes the file, or a
    # repo that never ran `enable` would get the noise back.
    assert (not $wrote)
    assert $seeded
}

@test
def "a seeded repo reports one untracked line for .claude" [] {
    let root = temp-root
    mkdir $root
    ^git -C $root init --quiet
    gi enable --root $root | ignore
    # core.excludesFile is neutralised: a developer with a global ignore entry
    # for .claude would otherwise see this pass or fail for reasons that have
    # nothing to do with the file gi writes.
    let git = ["-C" $root "-c" "core.excludesFile=/dev/null"]
    let status = ^git ...$git status --porcelain | lines
    let named = ^git ...$git status --porcelain --untracked-files=all | lines
    rm -rf $root

    # The whole point of the file, measured rather than argued: the folder still
    # announces that gi wrote there, and the seeds inside it are quiet.
    assert equal $status ["?? .claude/"]
    assert equal $named ["?? .claude/.gitignore"]
}

# =============================================================================
# status — what is seeded here, and what this session is bound to
# =============================================================================

@test
def "status reports the session canvas from the environment" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let unbound = gi --root $root
    let bound = with-env { GI_CANVAS: "/repo/gi/session-abc.md" } { gi --root $root }
    rm -rf $root

    # Activation is per session, so status answers "am I in a canvas session"
    # from the environment — there is no repo-side flag to read.
    assert equal $unbound.canvas null
    assert equal $bound.canvas "/repo/gi/session-abc.md"
}

@test
def "status returns absolute paths regardless of cwd" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let expected = $root | path expand | path join ".claude" "output-styles" "canvas.md"
    let orig = $env.PWD
    cd $root
    let status = gi --root $root
    cd $orig
    rm -rf $root

    # Data, not display: paths never shorten against PWD, so a consumer gets
    # the same value wherever status is called from.
    assert equal $status.style $expected
}

@test
def "status reports seeds differing from the module as stale" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let fresh = gi --root $root | get stale
    "user edit" | save --force ($root | path join ".claude" "skills" "git-intent" "SKILL.md")
    let edited = gi --root $root | get stale
    gi enable --root $root --force | ignore
    let refreshed = gi --root $root | get stale
    rm -rf $root

    assert equal $fresh []
    assert equal ($edited | each {|p| $p | path dirname | path basename }) ["git-intent"]
    assert equal $refreshed []
}

# =============================================================================
# launch — the activation payload and the guards that run before claude does
# =============================================================================

@test
def "launch settings carry the Canvas style and the Stop hook" [] {
    let with_hook = gi-launch-settings --hook | from json
    let without = gi-launch-settings | from json

    assert equal $with_hook.outputStyle "Canvas"
    assert equal ($with_hook.hooks.Stop | length) 1
    # The hook runs the entry script, not `-c` with an import string: the body
    # lives in a file the syntax check can see. `gi check` is that body, not a
    # verb anyone types, so mod.nu does not re-export it.
    assert ($with_hook.hooks.Stop.0.hooks.0.command | str contains "gi-hook.nu")
    # --no-hook keeps the proactive style and drops the floor — so the payload
    # must carry no Stop key at all, not an empty one.
    assert equal $without.outputStyle "Canvas"
    assert equal $without.hooks? null
}

@test
def "open seeds an unseeded repo instead of refusing" [] {
    let root = temp-root
    mkdir $root
    ^git -C $root init --quiet
    let launched = with-env {PATH: (stub-claude $root | append $env.PATH)} {
        gi open gi/plan.md --root $root | ignore
        # Read inside the try, so a launch that wrote nothing fails on the
        # assertion below rather than here — where it would skip the cleanup.
        try { open --raw ($root | path join "claude-args") } catch { "" }
    }
    let seeded = $root | path join ".claude" "output-styles" "canvas.md" | path exists
    let ignored = $root | path join ".claude" ".gitignore" | path exists
    let canvas = $root | path join "gi" "plan.md" | path exists
    rm -rf $root

    # outputStyle names a file that must exist here, or the session starts with
    # no style and gi is half on. Refusing was the old answer; seeding is the
    # new one, and it is what keeps a launch from dying after it has already
    # copied a fork.
    assert $seeded
    assert $canvas
    assert ($launched | str contains "--name gi/plan.md")
    # `open` cannot decline the ignore file — this is the repo that never ran
    # `enable`, and it is the one that would otherwise get the noise back.
    assert $ignored
}

@test
def "launch args bind the canvas session and name the session after it" [] {
    let sid = "11111111-2222-3333-4444-555555555555"

    # A minted id is declared with --session-id; one the canvas already carried
    # is returned to with --resume. One verb, and the canvas decides which.
    assert equal (gi-launch-args $sid "gi/plan.md" | first 4) ["--session-id" $sid "--name" "gi/plan.md"]
    assert equal (gi-launch-args $sid "gi/plan.md" --resume | first 4) ["--resume" $sid "--name" "gi/plan.md"]

    # The caller's own claude flags ride along last, untouched.
    assert equal (
        gi-launch-args $sid "gi/plan.md" "--dangerously-skip-permissions" "--model" "opus" | last 3
    ) ["--dangerously-skip-permissions" "--model" "opus"]
}

@test
def "the launch states the canvas path in the system prompt" [] {
    # An env var is not in the model's context, so $env.GI_CANVAS cannot be how
    # the agent learns which file it is bound to — the launch has to say it in
    # words, or the session opens by hunting the repo for a canvas. The path has
    # to be in the line; the wording around it is free to change.
    let args = gi-launch-args "11111111-2222-3333-4444-555555555555" "gi/plan.md"
    let at = $args | enumerate | where item == "--append-system-prompt" | get index | first
    assert ($args | get ($at + 1) | str contains "gi/plan.md")
}

@test
def "a flag typed where the canvas goes is not taken as the canvas" [] {
    # --root points at a directory that does not exist, so a guard-order
    # regression cannot reach the launcher and seed the developer's own checkout.
    let root = temp-root
    # --wrapped hands an undeclared flag before the doc to the positional, so
    # without this a typo would create a canvas named after the flag.
    let out = try { gi open --model opus --root $root; null } catch {|e| $e.msg }
    assert ($out | str contains "not a canvas path")

    # Declared flags parse in either position — which is why the one flag most
    # often typed with no canvas named is in the signature. Proof: with two
    # flags and no canvas, the one that lands in the doc slot is the *second*,
    # so the first was consumed as the flag it is.
    let named = try { gi open --dangerously-skip-permissions --model opus --root $root; null } catch {|e| $e.msg }
    assert ($named | str contains "--model is not a canvas path")
    assert (not ($root | path exists))
}

@test
def "the pass-through refuses the flags a canvas launch sets itself" [] {
    # A second --settings would win over gi's and take the style and the hook
    # with it; a forwarded session flag would unbind the launch from the canvas;
    # a second --append-system-prompt wins outright — `claude` keeps only the
    # last — and drops the line naming the canvas.
    for flag in ["--settings" "--settings={}" "--resume" "-c" "--name" "--append-system-prompt"] {
        let out = try { gi-reject-owned-flags ["--model" $flag]; "" } catch {|e| $e.msg }
        assert ($out | str contains "gi sets") $"($flag) should be refused"
    }

    # Everything else is the caller's business.
    assert equal (gi-reject-owned-flags ["--dangerously-skip-permissions" "--model" "opus"]) null
}

@test
def "the session plan resumes what the canvas records and mints when it holds none" [] {
    let sid = "11111111-2222-3333-4444-555555555555"

    let bound = gi-session-plan $sid
    let fresh = gi-session-plan null

    # One canvas, one session, for life: a recorded id is returned to, and only
    # a canvas holding none gets a new one.
    assert equal $bound {sid: $sid, resume: true, replaced: null}
    assert equal $fresh.resume false
    assert equal $fresh.replaced null
    assert ($fresh.sid != $sid)
}

@test
def "the session plan drops the recorded id for --new-session" [] {
    let sid = "11111111-2222-3333-4444-555555555555"
    let plan = gi-session-plan $sid --new-session

    # The way out of a canvas whose session is gone: mint regardless of what is
    # recorded, and hand back the id being dropped so the launcher can name it —
    # the canvas is untracked by default, so nothing else holds it.
    assert equal $plan.resume false
    assert equal $plan.replaced $sid
    assert ($plan.sid != $sid)
}

@test
def "the plan reports no drop when --new-session hits an unbound canvas" [] {
    let plan = gi-session-plan null --new-session

    # Not an error: the flag says "start fresh", and a canvas with no session
    # already is. There is just no dropped id to name.
    assert equal $plan.resume false
    assert equal $plan.replaced null
}

@test
def "a fork takes the next number in a flat series" [] {
    # Plain case, and numbering continues past the whole series.
    assert equal (gi-fork-name "plan.md" ["plan.md"]) "plan_1.md"
    assert equal (gi-fork-name "plan.md" ["plan.md" "plan_1.md" "plan_2.md"]) "plan_3.md"

    # A fork of a fork joins the same series instead of nesting into
    # `plan_1_1.md`: every canvas grown from one document sorts next to it.
    assert equal (gi-fork-name "plan_1.md" ["plan.md" "plan_1.md" "plan_3.md"]) "plan_4.md"

    # Max+1, never the first gap: `plan_2.md` was named somewhere outside the
    # repo before it was deleted, and must not be handed to another canvas.
    assert equal (gi-fork-name "plan.md" ["plan.md" "plan_1.md" "plan_3.md"]) "plan_4.md"

    # Only siblings of the same stem and extension are part of the series.
    assert equal (gi-fork-name "plan.md" ["plan.md" "plan_7.txt" "other_9.md"]) "plan_1.md"
}

@test
def "forking copies the canvas and leaves the source bound as it was" [] {
    let root = temp-root
    let src = plain-canvas $root "gi/plan.md"
    let sid = "11111111-2222-3333-4444-555555555555"
    gi-stamp-session $src $sid
    let dst = gi-fork-canvas $src
    let copied = open --raw $dst
    let source_still = gi-frontmatter-session $src
    rm -rf $root

    assert equal ($dst | path basename) "plan_1.md"
    # The source keeps its session: forking is for carrying a document into
    # another conversation, not for moving it out of the one it has.
    assert equal $source_still $sid
    # The copy arrives naming that same session — the launcher is what mints a
    # fresh id and stamps it, exactly as --new-session does.
    assert ($copied | str contains $"session: ($sid)")
}

@test
def "a fork that cannot be stamped fails before the copy exists" [] {
    let root = temp-root
    let src = plain-canvas $root "gi/broken.md"
    "---\nsession: 11111111-2222-3333-4444-555555555555\n\n# no closing fence\n" | save --force $src
    let out = try { gi-fork-canvas $src; "" } catch {|e| $e.msg }
    let left = ls ($root | path join "gi") | get name | path basename
    rm -rf $root

    # The error belongs to the source, and it has to arrive before the copy: the
    # same throw after `cp` left an orphan bound to the source's session and
    # burned a name out of the series, since numbering is max+1 and never
    # reuses the gap.
    assert ($out | str contains "frontmatter is not closed")
    assert equal $left ["broken.md"]
}

@test
def "forking a canvas that is not there is an error, not a new canvas" [] {
    let root = temp-root
    let out = try { gi-fork-canvas ($root | path join "gi" "missing.md"); "" } catch {|e| $e.msg }
    rm -rf $root

    # --fork names a source, so an absent file cannot mean "create it" the way
    # a plain `gi open` does.
    assert ($out | str contains "no canvas to fork")
}

@test
def "open --fork launches the copy and leaves the source binding alone" [] {
    let root = temp-root
    mkdir $root
    ^git -C $root init --quiet
    let src = plain-canvas $root "gi/plan.md"
    let sid = "11111111-2222-3333-4444-555555555555"
    gi-stamp-session $src $sid
    let launched = with-env {PATH: (stub-claude $root | append $env.PATH)} {
        gi open gi/plan.md --fork --root $root | ignore
        try { open --raw ($root | path join "claude-args") } catch { "" }
    }
    let source_still = gi-frontmatter-session $src
    let fork_sid = gi-frontmatter-session ($root | path join "gi" "plan_1.md")
    rm -rf $root

    # The whole of --fork through the real command: the copy is what opens, on
    # an id of its own declared with --session-id (never --resume, which would
    # try to return to the source's conversation), and the source keeps its
    # binding.
    assert ($launched | str contains "--name gi/plan_1.md")
    assert ($launched | str contains $"--session-id ($fork_sid)")
    assert equal $source_still $sid
    assert ($fork_sid != $sid)
}

@test
def "the fork flags refuse the two ways they cannot mean anything" [] {
    # Same reason as above: a guard that stopped firing must not reach the
    # launcher and seed the repo the suite is running in.
    let root = temp-root
    # --fork is the one case where the positional names a source, so with no
    # canvas named there is nothing to copy.
    let no_doc = try { gi open --fork --root $root; "" } catch {|e| $e.msg }
    assert ($no_doc | str contains "--fork needs the canvas")

    # Both mint an id, but on different files — the pair names two intentions
    # at once. Refused before anything is copied or launched.
    let both = try { gi open gi/plan.md --fork --new-session --root $root; "" } catch {|e| $e.msg }
    assert ($both | str contains "cannot be combined")
    assert (not ($root | path exists))
}

@test
def "stamping a session creates the frontmatter block when there is none" [] {
    let root = temp-root
    let doc = plain-canvas $root "gi/plain.md"
    let before = open --raw $doc
    gi-stamp-session $doc "11111111-2222-3333-4444-555555555555"
    let after = open --raw $doc
    let sid = gi-frontmatter-session $doc
    rm -rf $root

    assert equal $sid "11111111-2222-3333-4444-555555555555"
    # The canvas's own content survives untouched below the new block.
    assert ($after | str ends-with $before)
}

@test
def "stamping a session replaces an id already recorded" [] {
    let root = temp-root
    let doc = plain-canvas $root "gi/plain.md"
    gi-stamp-session $doc "11111111-2222-3333-4444-555555555555"
    gi-stamp-session $doc "99999999-8888-7777-6666-555555555555"
    let raw = open --raw $doc
    let sid = gi-frontmatter-session $doc
    rm -rf $root

    # This is what `gi open --new-session` does: the canvas names one session,
    # never two, so the old key is overwritten rather than joined.
    assert equal $sid "99999999-8888-7777-6666-555555555555"
    assert equal ($raw | lines | where $it starts-with "session:" | length) 1
}

@test
def "stamping a session leaves a session-like line in the prose alone" [] {
    let root = temp-root
    mkdir ($root | path join "gi")
    let doc = $root | path join "gi" "prose.md"
    "---\nsession: 11111111-2222-3333-4444-555555555555\n---\n\nsession: not frontmatter\n" | save $doc
    gi-stamp-session $doc "99999999-8888-7777-6666-555555555555"
    let body = open --raw $doc | lines | last
    rm -rf $root

    # The rewrite is scoped to the block above the closing fence.
    assert equal $body "session: not frontmatter"
}

@test
def "stamping a session names the file when the frontmatter is not closed" [] {
    let root = temp-root
    mkdir ($root | path join "gi")
    let doc = $root | path join "gi" "broken.md"
    "---\ntitle: my plan\n" | save $doc
    let out = try { gi-stamp-session $doc "11111111-2222-3333-4444-555555555555"; null } catch {|e| $e.msg }
    rm -rf $root

    # Indexing past the split would throw "Row number too large", which names
    # neither the file nor what is wrong with it.
    assert ($out | str contains "frontmatter is not closed")
    assert ($out | str contains "broken.md")
}

@test
def "stamping a session joins an existing frontmatter block" [] {
    let root = temp-root
    mkdir ($root | path join "gi")
    let doc = $root | path join "gi" "titled.md"
    "---\ntitle: my plan\n---\n\n# Working area\n" | save $doc
    gi-stamp-session $doc "11111111-2222-3333-4444-555555555555"
    let meta = open --raw $doc | lines | skip 1 | take until {|l| $l == "---" } | str join "\n" | from yaml
    rm -rf $root

    # One block, not two: a hand-written key keeps its place.
    assert equal $meta {session: "11111111-2222-3333-4444-555555555555" title: "my plan"}
}

# No tests here for `gi --force`, `gi enable --no-hook`, `gi enable <doc>`, or
# `gi <doc>`: each verb is its own command, so the parser rejects those before
# the code runs — and a parse error cannot be caught by `try`, which is the
# point.
#
# Nor for "open refuses a bound canvas" / "resume needs a session": there is
# one verb now, and the canvas decides which half of it runs.

# =============================================================================
# check — the Stop hook decision (contract)
# =============================================================================

# What the hook must always block: an answer, not a note. Over the line budget
# rather than merely long, so the fixture survives a change to GI_HOOK_MAX_LEN.
const BLOCKED_ANSWER = "A full answer for the canvas,\nwritten over more lines\nthan a chat note\nis ever allowed to take,\nand still going."

# GI_CANVAS is what makes the hook enforce anything, so every rule test binds
# one. cwd defaults to a non-repo dir: the branch guard must see the payload's
# state, not whatever branch the test runner's own repo happens to be on.
def block-decision [payload: record, --canvas: string]: nothing -> any {
    let canvas = $canvas | default "/elsewhere/gi/canvas.md"
    with-env { GI_CANVAS: $canvas } {
        {cwd: $nu.temp-dir} | merge $payload | to json | gi check
    }
}

@test
def "check stands down when no canvas is bound to the session" [] {
    let out = with-env { GI_CANVAS: null } {
        {cwd: $nu.temp-dir, last_assistant_message: $BLOCKED_ANSWER} | to json | gi check
    }

    # A plain `claude` session never sets GI_CANVAS, so the same hook body is
    # inert there — this is the whole on/off switch.
    assert equal $out null
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
def "check blocks prose over the line budget" [] {
    let out = block-decision { last_assistant_message: "First I changed the parser.\nThen I updated the tests.\nHere is why it matters.\nAnd here is what is next.\nOne more thought." }
    assert equal ($out | from json | get decision) "block"
}

@test
def "check blocks a single line over the budget" [] {
    let out = block-decision { last_assistant_message: (1..100 | each { "prose" } | str join " ") }
    assert equal ($out | from json | get decision) "block"
}

@test
def "check treats an empty message as allowed" [] {
    assert equal (block-decision { last_assistant_message: "" }) null
}

@test
def "check treats a non-object payload as empty, inside the contract" [] {
    # cd away from the test runner's repo: a payload with no cwd falls back to
    # PWD, and this repo's own branch would drive the branch guard.
    let orig = $env.PWD
    cd $nu.temp-dir
    let outs = ['"hi"' '123' 'null' '[1, 2]'] | each {|raw|
        with-env { GI_CANVAS: "/elsewhere/canvas.md" } { $raw | gi check }
    }
    cd $orig

    assert equal $outs []
}

@test
def "check with no stdin treats the event as empty" [] {
    # Run by hand (`claude-nu gi check`) there is no piped event; the input is
    # nothing, not a string, and must not be refused at the signature.
    let orig = $env.PWD
    cd $nu.temp-dir
    let out = with-env { GI_CANVAS: "/elsewhere/canvas.md" } { gi check }
    cd $orig

    assert equal $out null
}

@test
def "check names the bound canvas in the block reason" [] {
    let root = temp-root
    git init -qb canvas-work $root
    let reason = block-decision { last_assistant_message: $BLOCKED_ANSWER, cwd: $root } --canvas ($root | path join "gi" "plan.md")
    | from json
    | get reason
    rm -rf $root

    # Shortened against the repo root: the agent reads this path in a message.
    assert ($reason | str contains "`gi/plan.md`")
}

@test
def "check shortens the canvas path from a subdirectory cwd" [] {
    let root = temp-root
    git init -qb canvas-work $root
    mkdir ($root | path join "sub")
    let reason = block-decision { last_assistant_message: $BLOCKED_ANSWER, cwd: ($root | path join "sub") } --canvas ($root | path join "gi" "plan.md")
    | from json
    | get reason
    rm -rf $root

    # The repo root comes from git, not from the event's cwd, so a session that
    # drifted into a subdirectory still names the canvas the short way.
    assert ($reason | str contains "`gi/plan.md`")
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
    # Any non-empty message reaches the budget parse, which is what breaks here.
    let out = with-env { GI_HOOK_MAX_LEN: "abc" } {
        block-decision { last_assistant_message: "a chat line long enough to be judged" }
    }

    let decision = $out | from json
    assert equal $decision.decision "block"
    assert ($decision.reason | str contains "failed internally")
}

# =============================================================================
# gi-allowed — the allow-rule, tested directly
# =============================================================================

@test
def "allow-rule passes empty, short notes, and short pointers" [] {
    assert (gi-allowed "")
    assert (gi-allowed "done")
    assert (gi-allowed "DONE!")
    assert (gi-allowed "noted")
    assert (gi-allowed "moved to `docs/plan.md`")
    assert (gi-allowed "see commands.nu:1180")
    assert (gi-allowed "next → tests/test_gi.nu")
    # A short note needs no path: it hides no answer from the canvas.
    assert (gi-allowed "waiting on the background agent before drafting")
    # A note and a pointer are two lines; up to 3 breaks are inside the budget.
    assert (gi-allowed "waiting on the survey agent.\nnext → `todo/plan.md`")
}

@test
def "allow-rule blocks messages over either budget" [] {
    let long = 1..100 | each { "prose" } | str join " " # 599 chars, one line
    assert (not (gi-allowed $long))
    assert (not (gi-allowed "one\ntwo\nthree\nfour\nfive"))
}

@test
def "allow-rule budget is tunable via GI_HOOK_MAX_LEN" [] {
    with-env { GI_HOOK_MAX_LEN: "10" } {
        assert (not (gi-allowed "short `f.nu`")) # 12 chars > 10 → blocked
    }
    with-env { GI_HOOK_MAX_LEN: "500" } {
        assert (gi-allowed "short `f.nu`")
    }
}

# =============================================================================
# gi-off-canvas — the `chat:` aside
# =============================================================================

# A transcript holding the given records in order. Strings become authored user
# turns; a record is written as-is (for the tool-result rows that are user-type
# but not human turns).
def transcript-of [records: list<any>]: nothing -> path {
    let file = $nu.temp-dir | path join $"gi-transcript-(random uuid).jsonl"
    $records
    | each {|r|
        if ($r | describe) == "string" { {type: "user" message: {role: "user" content: $r}} } else { $r }
    }
    | each { to json --raw }
    | str join "\n"
    | save --force $file
    $file
}

@test
def "off-canvas is true when the last user message opens with the marker" [] {
    let file = transcript-of ["chat: what does --fork do?"]
    let out = gi-off-canvas $file
    rm $file

    assert $out
}

@test
def "off-canvas ignores case and leading whitespace" [] {
    let file = transcript-of ["  Chat: quick question"]
    let out = gi-off-canvas $file
    rm $file

    assert $out
}

@test
def "off-canvas is false without the marker" [] {
    let file = transcript-of ["rewrite the import section"]
    let out = gi-off-canvas $file
    rm $file

    assert (not $out)
}

@test
def "off-canvas reads the last human turn, not an earlier marked one" [] {
    # An aside is spent when it is answered: the next turn is canvas work again.
    let file = transcript-of ["chat: what does --fork do?" "now rewrite the import section"]
    let out = gi-off-canvas $file
    rm $file

    assert (not $out)
}

@test
def "off-canvas looks past the tool-result records of the same turn" [] {
    # Tool results are user-type records; only authored turns carry the marker.
    let tool_result = {type: "user" message: {role: "user" content: [{type: "tool_result" content: "ok"}]}}
    let file = transcript-of ["chat: what does --fork do?" $tool_result $tool_result]
    let out = gi-off-canvas $file
    rm $file

    assert $out
}

@test
def "off-canvas leaves the floor up when there is no transcript" [] {
    assert (not (gi-off-canvas ""))
    assert (not (gi-off-canvas ($nu.temp-dir | path join $"gi-missing-(random uuid).jsonl")))
}

@test
def "check lets a marked turn end with any answer" [] {
    let file = transcript-of ["chat: what does --fork do?"]
    # The fixture the rule always blocks, so the marker is what clears it here.
    let out = block-decision { last_assistant_message: $BLOCKED_ANSWER, transcript_path: $file }
    rm $file

    assert equal $out null
}

@test
def "check lets a marked turn end on a protected branch" [] {
    # The branch guard protects the trunk from gi commits; an aside makes none.
    let root = temp-root
    git init -qb master $root
    let file = transcript-of ["chat: which branch am I on?"]
    let out = block-decision { last_assistant_message: "You are on `master`.", cwd: $root, transcript_path: $file }
    rm -rf $root
    rm $file

    assert equal $out null
}

@test
def "check still blocks prose when the turn is not marked" [] {
    let file = transcript-of ["rewrite the import section"]
    let out = block-decision { last_assistant_message: $BLOCKED_ANSWER, transcript_path: $file }
    rm $file

    assert equal ($out | from json | get decision) "block"
}

# =============================================================================
# import — a session's dialogue as the canvas
# =============================================================================

const FIXTURE_SESSION = '99bf0e5b-212c-4891-abb2-6bc585af2ea0'
const FIXTURES_SESSIONS_DIR = path self fixtures/sessions

# Stage a fixture session under a temp HOME: resolve-session-file finds a UUID by
# globbing ~/.claude/projects, so this is what makes the env-var path resolvable
# the way it is in a live session.
def stage-session [home: path]: nothing -> nothing {
    let dir = $home | path join ".claude" "projects" "-tmp-proj"
    mkdir $dir
    cp ($FIXTURES_SESSIONS_DIR | path join $"($FIXTURE_SESSION).jsonl") $dir
}

@test
def "import text carries the canvas header, the pointer note, and the dialogue" [] {
    let body = gi-import-text ($FIXTURES_SESSIONS_DIR | path join $"($FIXTURE_SESSION).jsonl")

    assert ($body | str starts-with "---\n") # export-session's frontmatter
    assert str contains $body "# Working area"
    assert str contains $body $"($FIXTURE_SESSION).jsonl`" # pointer to the full record
    assert str contains $body "## User"
    # The session title is replaced, not joined — one H1 in a committed doc.
    assert equal ($body | lines | where $it starts-with "# ") ["# Working area"]
    assert not ($body | str contains "> [Bash:") # tool calls dropped by default
}

# The note is the copy that survives — the terminal line scrolls away — so it
# must not claim a live session, or a missing tail, for an older named one.
@test
def "the import note claims a missing tail only for the live session" [] {
    let file = $FIXTURES_SESSIONS_DIR | path join $"($FIXTURE_SESSION).jsonl"
    let named = gi-import-text $file
    let live = gi-import-text $file --live

    assert ($named | str contains $"Imported from session ($FIXTURE_SESSION | str substring 0..7)")
    assert not ($named | str contains "live session")
    assert not ($named | str contains "is missing")
    assert ($live | str contains "Imported from the live session")
    assert ($live | str contains "The turn that ran the import is missing")
}

@test
def "import text with the tools flag keeps one-line tool placeholders" [] {
    let body = gi-import-text ($FIXTURES_SESSIONS_DIR | path join $"($FIXTURE_SESSION).jsonl") --tools

    assert str contains $body "> [Bash:"
    assert str contains $body "tool calls are one-line placeholders" # the note matches the content
}

@test
def "import writes a session-keyed canvas" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let status = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: $FIXTURE_SESSION} {
        gi import --root $root
    }
    let body = open --raw $status.doc
    rm -rf $root $home

    assert equal ($status.doc | path basename) $"session-($FIXTURE_SESSION | str substring 0..7).md"
    assert str contains $body "## User"
}

# The reason the session became a parameter: from the REPL there is no live
# session to fall back on, and the one being imported is rarely the newest.
@test
def "import takes a named session, with no live session in the environment" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let status = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: null} {
        gi import $FIXTURE_SESSION --root $root
    }
    let body = open --raw $status.doc
    rm -rf $root $home

    assert equal ($status.doc | path basename) $"session-($FIXTURE_SESSION | str substring 0..7).md"
    assert str contains $body "## User"
}

# The other spelling the signature promises: a .jsonl path, which the default
# doc name has to key on the same way it keys on a UUID.
@test
def "import takes a session as a .jsonl path" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let file = $home | path join ".claude" "projects" "-tmp-proj" $"($FIXTURE_SESSION).jsonl"
    let status = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: null} {
        gi import $file --root $root
    }
    rm -rf $root $home

    assert equal ($status.doc | path basename) $"session-($FIXTURE_SESSION | str substring 0..7).md"
}

@test
def "the to flag names the canvas, with no session named" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let status = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: $FIXTURE_SESSION} {
        gi import --to notes/plan.md --root $root
    }
    rm -rf $root $home

    assert equal ($status.doc | path basename) "plan.md"
}

@test
def "import refuses to overwrite an existing doc" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let out = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: $FIXTURE_SESSION} {
        gi import --root $root | ignore
        try { gi import --root $root | ignore; null } catch {|e| $e.msg }
    }
    rm -rf $root $home

    assert ($out | str contains "already exists")
}

@test
def "import with no session errors when no live session id is exported" [] {
    let root = temp-root
    let out = with-env {CLAUDE_CODE_SESSION_ID: null} {
        try { gi import --root $root | ignore; null } catch {|e| $e.msg }
    }
    rm -rf $root

    assert ($out | str contains "no live session")
}

@test
def "the gitignore flag keeps the import out of git, beside the doc" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let status = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: $FIXTURE_SESSION} {
        gi import --root $root --gitignore
    }
    let ignored = open --raw ($root | path join "gi" ".gitignore") | lines
    rm -rf $root $home

    assert equal $ignored [($status.doc | path basename)]
}

@test
def "the commit flag puts the import into git history" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    mkdir $root
    git -C $root init --quiet
    git -C $root config user.email "test@example.com"
    git -C $root config user.name "test"
    with-env {HOME: $home CLAUDE_CODE_SESSION_ID: $FIXTURE_SESSION} {
        gi import --root $root --commit | ignore
    }
    let committed = git -C $root show --name-only --format="%s" HEAD | lines
    rm -rf $root $home

    assert equal $committed.0 $"gi: import session ($FIXTURE_SESSION | str substring 0..7) as the working doc"
    assert ($committed | any {|l| $l | str ends-with ".md" })
}

@test
def "commit and gitignore flags contradict each other" [] {
    let out = try { gi import --commit --gitignore; null } catch {|e| $e.msg }
    assert ($out | str contains "contradict")
}

# =============================================================================
# frontmatter — the session id a canvas carries for resume
# =============================================================================

@test
def "an imported canvas carries the full session id in its frontmatter" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let status = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: $FIXTURE_SESSION} {
        gi import --root $root
    }
    let sid = gi-frontmatter-session $status.doc
    rm -rf $root $home

    # The 8-char key names the file; the frontmatter carries the full UUID resume needs.
    assert equal $sid $FIXTURE_SESSION
}

@test
def "frontmatter-session is null for a canvas without a session" [] {
    let root = temp-root
    plain-canvas $root "gi/plain.md" | ignore
    let sid = gi-frontmatter-session ($root | path join "gi" "plain.md")
    rm -rf $root

    assert equal $sid null
}
