# claude-nu example - suggest a pipeline to try, and paste it back into the
# command line.
#
# The module names itself here because the convention is meant to be copied: a
# module reusing this file changes $MODULE and nothing else.
#
# The examples are not a second list to maintain: they are the `@example`
# attributes the module's own commands already carry, read at runtime from
# `scope commands`. `dotnu examples-update` runs those blocks and writes the
# real output back into `--result`, so an example that died in a rename gets
# caught at authoring time instead of being suggested here.

const MODULE = 'claude-nu'

# Suggest an example to run.
#
# With no argument it returns the examples as a table, so they compose like any
# other data. Given a slug — tab-complete it, the menu shows the whole pipeline
# next to each one — it writes that pipeline into your command line, ready to
# read, edit and run. You execute it, not this command.
#
# That last step is REPL-only: `commandline edit` has no buffer to write to
# anywhere else, so a script should take the table and do its own thing with it.
@category claude-nu
export def main [
    slug?: string@"nu-complete claude-nu examples" # Which example to paste; omit to get the table
]: nothing -> any {
    if $slug == null { return (example-table) }

    let found = example-table | where slug == $slug
    if ($found | is-empty) {
        error make --unspanned {
            msg: $"no example named '($slug)'"
            help: "run `claude-nu example` with no argument to see them all"
        }
    }

    commandline edit --replace ($found | first | get example)
}

# Every `@example` carried by the loaded claude-nu commands, keyed by a slug.
#
# Why `scope commands` and not `dotnu find-examples`: the file parse is the
# authoring side. It returns no description and drops any example without a
# `--result`, while the menu needs exactly the description and must show the
# ones that have no result too.
export def example-table []: nothing -> table<slug: string, description: string, example: string> {
    # Not `scope commands | where name starts-with 'claude-nu '`: that reads the
    # names the import happened to produce, so `use claude-nu *` — which imports
    # them unprefixed — silently dropped every example but the module's own.
    # `scope modules` gives the module-relative names and their decl_id, which
    # both import forms share, so the menu and its slugs come out identical.
    let exported = scope modules | where name == $MODULE | get 0?.commands? | default []
    if ($exported | is-empty) { return [] }

    let examples = scope commands | where decl_id in $exported.decl_id | select decl_id examples

    $exported
    | join $examples decl_id
    | each {|cmd|
        $cmd.examples | each {|ex| {command: $cmd.name description: $ex.description example: $ex.example} }
    }
    | flatten
    | slugify-examples
}

# Give every example a short, typeable key.
#
# The description is the source: it already says what the example is for, so the
# slug reads as a label instead of an index nobody can remember.
export def slugify-examples []: table -> table<slug: string, description: string, example: string> {
    insert slug {|row| slug-for $row.description $row.command }
    | dedupe-slugs
    | select slug description example
}

def slug-for [description: string command: string]: nothing -> string {
    let from_description = $description | kebab

    # Not decoration: dotnu writes `@example ''` on nearly every one of its
    # examples, so a module reusing this convention arrives with no descriptions
    # at all. Then the command it documents is the only label there is.
    if $from_description != '' { $from_description } else { $command | kebab }
}

def kebab []: string -> string {
    str lowercase
    # Drop the apostrophe before the rest becomes hyphens: "project's" is one
    # word, and `project-s` reads as two.
    | str replace --all "'" ''
    | str replace --all --regex '[^a-z0-9]+' '-'
    | str trim --char '-'
}

# Two examples described the same way collide on one key, and the second becomes
# unreachable. Number the repeats instead of losing them.
#
# Again dotnu, not a hypothetical: a file whose examples all carry `@example ''`
# falls back to the command name, and a command with two examples then produces
# that name twice.
def dedupe-slugs []: table -> table {
    let rows = $in

    $rows
    | enumerate
    | each {|entry|
        # Not `$it`: `where` binds `$it` to its own row, which shadows the outer
        # one and makes every comparison true.
        let taken = $rows | first $entry.index | where {|r| $r.slug == $entry.item.slug } | length

        if $taken == 0 { $entry.item } else { $entry.item | update slug $"($entry.item.slug)-($taken + 1)" }
    }
}

# Why `sort: false`: the menu is authored, not alphabetical. Sorting by slug
# would order the examples by whatever their descriptions happen to start with,
# while the order they come in — the module's own pipelines first, then each
# command's, in the order the code declares them — is the order a reader should
# meet them in. Any module copying this convention wants the same.
export def "nu-complete claude-nu examples" []: nothing -> record<options: record, completions: table<value: string, description: string>> {
    {
        options: {sort: false}
        completions: (example-table | select slug example | rename value description)
    }
}
