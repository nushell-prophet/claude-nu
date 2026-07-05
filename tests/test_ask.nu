use std/assert
use std/testing *

# `ask.nu` exports `main`, surfaced as the `ask` command on import.
use ../claude-nu/ask.nu

# Only the no-input guard is unit-testable: every other path shells out to the
# real `claude` binary. That guard must reject before any child runs.

@test
def "ask errors when neither prompt nor stdin is given" [] {
    # Why: pipe an explicit null so the guard fires on truly-empty input and the
    # test never shells out to the real claude binary.
    let err = try { null | ask; "" } catch {|e| $e.msg }
    assert str contains $err "no prompt given"
}

@test
def "ask errors when prompt and stdin are only whitespace" [] {
    # Why: blank/whitespace sources are trimmed away, so they count as no input
    # rather than being sent to claude as an empty prompt.
    let err = try { "   " | ask "   "; "" } catch {|e| $e.msg }
    assert str contains $err "no prompt given"
}
