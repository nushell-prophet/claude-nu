use std assert
use std/testing *

use ../completions/nu.nu *

const FIXTURE_MULTIWORD = path self fixtures/multiword-subcommand.nu

# =============================================================================
# parse-script-commands tests
# =============================================================================

@test
def "parse-script-commands extracts multi-word subcommand names" [] {
    let cmds = parse-script-commands $FIXTURE_MULTIWORD
    let names = $cmds | get name | sort

    assert equal $names ['bar' 'bar baz' 'qux']
}

@test
def "parse-script-commands extracts flags per subcommand" [] {
    let cmds = parse-script-commands $FIXTURE_MULTIWORD

    let bar_baz = $cmds | where name == 'bar baz' | get flags.0 | sort
    assert equal $bar_baz ['depth' 'verbose']
}

# =============================================================================
# nu-complete nu subcommands tests
# =============================================================================

@test
def "nu-complete nu subcommands returns subcommand names with no args typed" [] {
    let context = $"nu ($FIXTURE_MULTIWORD) "
    let result = nu-complete nu subcommands $context | sort

    assert equal $result ['bar' 'bar baz' 'qux']
}

@test
def "nu-complete nu subcommands returns flags for single-word subcommand" [] {
    let context = $"nu ($FIXTURE_MULTIWORD) bar "
    let result = nu-complete nu subcommands $context

    assert equal $result ['--alpha']
}

@test
def "nu-complete nu subcommands returns flags for multi-word subcommand" [] {
    # Why: multi-word subcommand names like "bar baz" must match against the
    # joined typed args, not against individual tokens. Regression test for
    # the bug where neither "bar" nor "baz" alone matched "bar baz".
    let context = $"nu ($FIXTURE_MULTIWORD) bar baz "
    let result = nu-complete nu subcommands $context | sort

    assert equal $result ['--depth' '--verbose']
}

@test
def "nu-complete nu subcommands prefers longest matching prefix" [] {
    # Why: with names ["bar", "bar baz"], typing "bar baz" must resolve to
    # "bar baz" (longest match), not "bar" (shorter prefix that also matches).
    let context = $"nu ($FIXTURE_MULTIWORD) bar baz "
    let result = nu-complete nu subcommands $context

    # bar baz's flags, not bar's --alpha
    assert ('--alpha' not-in $result)
}
