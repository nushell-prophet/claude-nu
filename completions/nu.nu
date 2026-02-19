# Nushell custom completions for `nu`
# Completes script subcommands and their flags via `ast --flatten`

def parse-script-commands [script: string] {
    ast --flatten (open $script --raw)
    | where { $in.shape != shape_flag }
    | window 3 --remainder
    | where { $in.0.shape == shape_internalcall and ($in.0.content in [def "export def"]) }
    | each {|w|
        let name = $w.1.content | str trim --char "'" | str trim --char '"'
        let sig = $w | get 2?.content? | default ''
        {
            name: $name
            flags: ($sig | parse --regex '--(\w[\w-]*)' | get capture0)
        }
    }
    | where { $in.name starts-with 'main ' }
    | update name { str replace 'main ' '' }
}

def "nu-complete nu subcommands" [context: string] {
    let script = $context
        | split row -r '\s+'
        | skip 1
        | where { ($in | str ends-with '.nu') and ($in | path exists) }
        | get 0?

    if $script == null { return null }

    let cmds = parse-script-commands $script
    let subcmd_names = $cmds | get name

    let typed_args = $context
        | split row -r '\s+'
        | skip 1
        | where { not ($in | str starts-with '-') and not ($in | str ends-with '.nu') }

    let matches = $typed_args | where { $in in $subcmd_names }

    if ($matches | is-empty) {
        $subcmd_names
    } else {
        $cmds
        | where name == ($matches | last)
        | get flags.0
        | each { $"--($in)" }
    }
}

export extern main [
    ...args: string@"nu-complete nu subcommands"
    --help (-h)
]
