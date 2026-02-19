# Nushell custom completions for `nu`
# Completes script subcommands and their flags via `ast --flatten`

const table_modes = [rounded basic compact compact_double heavy none reinforced with_love]
const error_styles = [fancy plain]
const log_levels = [error warn info debug trace]
const log_targets = [stdout stderr mixed file]

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
    --help (-h)                                        # Display the help message
    --commands (-c): string                            # Run the given commands and then exit
    --execute (-e): string                             # Run the given commands and then enter an interactive shell
    --include-path (-I): string                        # Set the NU_LIB_DIRS for the given script
    --interactive (-i)                                 # Start as an interactive shell
    --login (-l)                                       # Start as a login shell
    --table-mode (-m): string@$table_modes             # The table mode to use
    --error-style: string@$error_styles                # The error style to use
    --no-newline                                       # Print the result for -c without a newline
    --no-config-file (-n)                              # Start with no config file and no env file
    --no-history                                       # Disable reading and writing to command history
    --no-std-lib                                       # Start with no standard library
    --threads (-t): int                                # Threads to use for parallel commands
    --version (-v)                                     # Print the version
    --config: string                                   # Start with an alternate config file
    --env-config: string                               # Start with an alternate environment config file
    --lsp                                              # Start nu's language server protocol
    --ide-goto-def: int                                # Go to the definition of the item at the given position
    --ide-hover: int                                   # Give information about the item at the given position
    --ide-complete: int                                # List completions for the item at the given position
    --ide-check: int                                   # Run a diagnostic check on the given source
    --ide-ast                                          # Generate the ast on the given source
    --mcp                                              # Start nu's model context protocol server
    --plugin-config: string                            # Start with an alternate plugin registry file
    --plugins: string                                  # List of plugin executable files to load
    --log-level: string@$log_levels                    # Log level for diagnostic logs
    --log-target: string@$log_targets                  # Set the target for the log to output
    --log-include: string                              # Set the Rust module prefixes to include in the log output
    --log-exclude: string                              # Set the Rust module prefixes to exclude from the log output
    --stdin                                            # Redirect standard input to a command or script file
    --testbin: string                                  # Run internal test binary
    --experimental-options: string                     # Enable or disable experimental options
]
