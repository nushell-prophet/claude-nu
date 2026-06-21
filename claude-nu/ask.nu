# claude-nu ask - one-shot non-interactive Claude prompt
#
# Lives apart from the session-reading commands: it runs Claude rather than
# parsing its sessions. Import it on its own: `use claude-nu/ask.nu *`.

# Run a one-shot Claude prompt non-interactively and return its text response.
#
# Merges an optional positional prompt with optional piped stdin (prompt first,
# blank line, then stdin) and runs `claude --print --safe-mode`. At least one
# source must carry text. --safe-mode disables all customizations (CLAUDE.md,
# skills, plugins, hooks, MCP, ...); permissions still apply.
#
# `main`, not `ask`: a Nushell module can't export a command named the same as
# the module, so importing `ask.nu` surfaces this as the `ask` command.
export def main [
    prompt?: string # Prompt text; placed before piped stdin when both are given
    --here # Run in the current directory so claude sees the project (cwd, git status, recent commits)
    --keep-sbx-token # Keep the sandbox placeholder ANTHROPIC_API_KEY (when a real key or proxy base-URL is set)
]: [nothing -> string, string -> string] {
    let piped = $in
    let parts = [$prompt $piped] | compact | where ($it | str trim | is-not-empty)
    if ($parts | is-empty) {
        error make --unspanned {
            msg: "claude-nu ask: no prompt given"
            help: "pass an argument, pipe stdin, or both"
        }
    }
    # Why: in the sandbox ANTHROPIC_API_KEY is the literal placeholder 'proxy-managed';
    # a nested claude uses it verbatim and gets 'Invalid API key'. Dropping it (null) for
    # this child only makes claude fall back to stored login credentials, so it just works.
    # Keep it only when a real key or proxy base-URL is set (--keep-sbx-token).
    let key_env = if $keep_sbx_token { {} } else { {ANTHROPIC_API_KEY: null} }
    # Why: Claude injects the launch dir's env block (cwd, git status, recent commits)
    # even under --safe-mode, so a question answered from a repo leaks that repo. Run from
    # a neutral empty dir by default so the answer uses only the prompt; --here opts into
    # the current dir to include the project.
    let workdir = if $here {
        $env.PWD
    } else {
        let neutral = $nu.temp-dir | path join claude-nu-ask
        mkdir $neutral
        $neutral
    }
    cd $workdir
    with-env $key_env { $parts | str join "\n\n" | claude --print --safe-mode }
}
