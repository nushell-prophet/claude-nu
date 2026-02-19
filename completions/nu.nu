# Nushell custom completions for `nu`
# Completes script subcommands defined via `def "main <subcommand>"`

def "nu-complete nu subcommands" [context: string] {
    let script = $context
        | split row -r '\s+'
        | skip 1
        | where { ($in | str ends-with '.nu') and ($in | path exists) }
        | get 0?

    if $script == null { return null }

    ast --flatten (open $script --raw)
    | where { $in.shape != shape_flag }
    | window 2
    | where { $in.0.shape == shape_internalcall and ($in.0.content in [def "export def"]) }
    | each { $in.1.content }
    | str trim --char "'"
    | str trim --char '"'
    | where { $in starts-with 'main ' }
    | each { str replace 'main ' '' }
}

export extern main [
    ...args: string@"nu-complete nu subcommands"
    --help (-h)
]
