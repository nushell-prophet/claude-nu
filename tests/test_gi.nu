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

    # Canvases belong to the launcher: `gi open <doc>` creates one and binds a
    # session to it in the same breath, so a canvas seeded here would be an
    # unbound file nobody asked for.
    assert equal $status.doc null
    assert (not $gi_dir)
}

@test
def "a canvas path on enable without an import is rejected" [] {
    let out = try { gi enable notes/plan.md; null } catch {|e| $e.msg }
    assert ($out | str contains "makes no canvas")
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
    assert equal $names ["gi-canvas" "git-intent" "git-intent-distill" "git-intent-squash-archive"]
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

# =============================================================================
# status — what is seeded here, and what this session is bound to
# =============================================================================

@test
def "status reports the session canvas from the environment" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let unbound = gi status --root $root
    let bound = with-env { GI_CANVAS: "/repo/gi/session-abc.md" } { gi status --root $root }
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
    let status = gi status --root $root
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
    let fresh = gi status --root $root | get stale
    "user edit" | save --force ($root | path join ".claude" "skills" "git-intent" "SKILL.md")
    let edited = gi status --root $root | get stale
    gi enable --root $root --force | ignore
    let refreshed = gi status --root $root | get stale
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
    assert ($with_hook.hooks.Stop.0.hooks.0.command | str contains "claude-nu gi check")
    # --no-hook keeps the proactive style and drops the floor — so the payload
    # must carry no Stop key at all, not an empty one.
    assert equal $without.outputStyle "Canvas"
    assert equal $without.hooks? null
}

@test
def "open refuses to launch before the repo is seeded" [] {
    let root = temp-root
    mkdir $root
    let out = try { gi open gi/plan.md --root $root; null } catch {|e| $e.msg }
    rm -rf $root

    # outputStyle names a file that must exist here, or the session would start
    # with no style and gi would be half on.
    assert ($out | str contains "not seeded")
}

@test
def "resume on a missing canvas errors before launching" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let out = try { gi resume ($root | path join "gi" "nope.md") --root $root; null } catch {|e| $e.msg }
    rm -rf $root

    assert ($out | str contains "no such canvas")
}

@test
def "resume on a canvas with no session errors before launching" [] {
    let root = temp-root
    gi enable --root $root | ignore
    plain-canvas $root "gi/plain.md"
    let out = try { gi resume ($root | path join "gi" "plain.md") --root $root; null } catch {|e| $e.msg }
    rm -rf $root

    assert ($out | str contains "no `session:`")
}

@test
def "the canvas verb follows the file, not the flags that made it" [] {
    let root = temp-root
    let doc = plain-canvas $root "gi/plain.md"
    let fresh = gi-canvas-verb $doc
    gi-stamp-session $doc "11111111-2222-3333-4444-555555555555"
    let bound = gi-canvas-verb $doc
    rm -rf $root

    # This is what `enable` prints as the next step. It used to be read off
    # --from-session, so an `enable` run days after the import sent the user to
    # `gi open`, which then refused the canvas.
    assert equal $fresh "open"
    assert equal $bound "resume"
}

@test
def "open refuses a canvas already bound to a session" [] {
    let root = temp-root
    gi enable --root $root | ignore
    let doc = plain-canvas $root "gi/plain.md"
    gi-stamp-session $doc "11111111-2222-3333-4444-555555555555"
    let out = try { gi open $doc --root $root; null } catch {|e| $e.msg }
    rm -rf $root

    # `claude --session-id` rejects an id already on disk, so a second open
    # could never work — the refusal names `gi resume` instead of leaking that.
    assert ($out | str contains "already bound to session")
}

@test
def "launch args bind the canvas session and name the session after it" [] {
    let sid = "11111111-2222-3333-4444-555555555555"

    # open mints the id, so it is passed as --session-id; resume returns to it.
    assert equal (gi-launch-args $sid "gi/plan.md") ["--session-id" $sid "--name" "gi/plan.md"]
    assert equal (gi-launch-args $sid "gi/plan.md" --continue) ["--resume" $sid "--name" "gi/plan.md"]
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

# No tests here for `gi resume` without a canvas, `gi status --force`,
# `gi enable --no-hook`, or `gi status <doc>`. Each verb is its own command
# now, so the parser rejects all four before the code runs — and a parse error
# cannot be caught by `try`, which is the point: the signature states the rule.

# =============================================================================
# check — the Stop hook decision (contract)
# =============================================================================

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
    let prose = "Long prose without any link signal that must be blocked by the rule"
    let out = with-env { GI_CANVAS: null } {
        {cwd: $nu.temp-dir, last_assistant_message: $prose} | to json | gi check
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
    let prose = "Long prose without any link signal that must be blocked by the rule"
    let reason = block-decision { last_assistant_message: $prose, cwd: $root } --canvas ($root | path join "gi" "plan.md")
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
    let prose = "Long prose without any link signal that must be blocked by the rule"
    let reason = block-decision { last_assistant_message: $prose, cwd: ($root | path join "sub") } --canvas ($root | path join "gi" "plan.md")
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
    let prose = "Long prose without any link signal that must be blocked by the rule"
    let out = with-env { GI_HOOK_MAX_LEN: "abc" } {
        block-decision { last_assistant_message: $prose }
    }

    let decision = $out | from json
    assert equal $decision.decision "block"
    assert ($decision.reason | str contains "failed internally")
}

# =============================================================================
# gi-allowed — the allow-rule, tested directly
# =============================================================================

@test
def "allow-rule passes empty, done, noted, and short pointers" [] {
    assert (gi-allowed "")
    assert (gi-allowed "done")
    assert (gi-allowed "DONE!")
    assert (gi-allowed "noted")
    assert (gi-allowed "moved to `docs/plan.md`")
    assert (gi-allowed "see commands.nu:1180")
    assert (gi-allowed "next → tests/test_gi.nu")
}

@test
def "allow-rule blocks prose and unanchored lines" [] {
    assert (not (gi-allowed "Here is a plain sentence with no link that should not be allowed in chat"))
    assert (not (gi-allowed "line one\nline two"))
    # Abbreviations and glued sentences are not filename signals.
    assert (not (gi-allowed "short prose with e.g an aside"))
    assert (not (gi-allowed "First thought ends.Next one starts"))
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
# enable --from-session — the live session's dialogue as the canvas
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

@test
def "import text with the tools flag keeps one-line tool placeholders" [] {
    let body = gi-import-text ($FIXTURES_SESSIONS_DIR | path join $"($FIXTURE_SESSION).jsonl") --tools

    assert str contains $body "> [Bash:"
    assert str contains $body "tool calls are one-line placeholders" # the note matches the content
}

@test
def "enable from-session writes a session-keyed canvas" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let status = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: $FIXTURE_SESSION} {
        gi enable --root $root --from-session
    }
    let body = open --raw $status.doc
    rm -rf $root $home

    assert equal ($status.doc | path basename) $"session-($FIXTURE_SESSION | str substring 0..7).md"
    assert str contains $body "## User"
}

@test
def "from-session refuses to overwrite an existing doc" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let out = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: $FIXTURE_SESSION} {
        gi enable --root $root --from-session | ignore
        try { gi enable --root $root --from-session | ignore; null } catch {|e| $e.msg }
    }
    rm -rf $root $home

    assert ($out | str contains "already exists")
}

@test
def "from-session errors when no live session id is exported" [] {
    let root = temp-root
    let out = with-env {CLAUDE_CODE_SESSION_ID: null} {
        try { gi enable --root $root --from-session | ignore; null } catch {|e| $e.msg }
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
        gi enable --root $root --from-session --gitignore
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
        gi enable --root $root --from-session --commit | ignore
    }
    let committed = git -C $root show --name-only --format="%s" HEAD | lines
    rm -rf $root $home

    assert equal $committed.0 $"gi: import session ($FIXTURE_SESSION | str substring 0..7) as the working doc"
    assert ($committed | any {|l| $l | str ends-with ".md" })
}

@test
def "commit and gitignore flags contradict each other" [] {
    let out = try { gi enable --from-session --commit --gitignore; null } catch {|e| $e.msg }
    assert ($out | str contains "contradict")
}

@test
def "the commit flag without an import errors" [] {
    let out = try { gi enable --commit; null } catch {|e| $e.msg }
    assert ($out | str contains "apply to the imported doc")
}

@test
def "the tools flag without an import errors" [] {
    let out = try { gi enable --tools; null } catch {|e| $e.msg }
    assert ($out | str contains "apply to the imported doc")
}

# =============================================================================
# frontmatter — the session id a canvas carries for resume
# =============================================================================

@test
def "a from-session canvas carries the full session id in its frontmatter" [] {
    let root = temp-root
    let home = temp-root
    stage-session $home
    let status = with-env {HOME: $home CLAUDE_CODE_SESSION_ID: $FIXTURE_SESSION} {
        gi enable --root $root --from-session
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
