use std/assert
use std/testing *

# `example.nu` exports `main` as the `example` command, plus the pure helpers the
# menu is built from.
use ../claude-nu/example.nu [example-table slugify-examples "nu-complete claude-nu examples"]
use ../claude-nu/example.nu

@test
def "slugs come from the description" [] {
    let got = [[command description example]; [messages "search this project's messages" "claude-nu messages 'x'"]]
        | slugify-examples

    # The apostrophe is dropped rather than hyphenated: `projects`, not `project-s`.
    assert equal ($got | get slug) ["search-this-projects-messages"]
}

@test
def "an example with no description falls back to its command" [] {
    # The command names come from `scope modules`, so they are module-relative:
    # `gi open`, not `claude-nu gi open`.
    let got = [[command description example]; ["gi open" "" "claude-nu gi open doc.md"]]
        | slugify-examples

    assert equal ($got | get slug) ["gi-open"]
}

@test
def "an example on the module itself keeps the module name" [] {
    let got = [[command description example]; ["claude-nu" "" "claude-nu sessions"]]
        | slugify-examples

    assert equal ($got | get slug) ["claude-nu"]
}

@test
def "repeated descriptions are numbered rather than lost" [] {
    let got = [[command description example]; [a "same" "a"] [b "same" "b"] [c "other" "c"]]
        | slugify-examples

    # Why numbering and not dropping: the second example is reachable only if it
    # has a key of its own.
    assert equal ($got | get slug) [same same-2 other]
}

@test
def "slugify keeps only the menu columns" [] {
    let got = [[command description example]; [a "one" "a"]] | slugify-examples

    assert equal ($got | columns) [slug description example]
}

@test
def "an unknown slug is an error, not silence" [] {
    let err = try { example "no-such-example"; "" } catch {|e| $e.msg }

    assert str contains $err "no example named 'no-such-example'"
}

@test
def "the table carries a row per example of the loaded commands" [] {
    # `example-table` reads `scope commands`, so inside this test file — where the
    # claude-nu module is not imported — it must come back empty instead of failing.
    assert equal (example-table) []
}

@test
def "the menu keeps the authored order instead of sorting" [] {
    let menu = nu-complete claude-nu examples

    # Why: sorting would reorder the examples by whatever their descriptions
    # start with. The order they arrive in — the module's own pipelines first,
    # then each command's, as the code declares them — is the intended one.
    assert equal $menu.options.sort false
}
