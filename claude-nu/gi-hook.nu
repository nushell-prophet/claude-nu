# Stop-hook entry point. Claude Code runs `nu --stdin <this file>` — see
# GI_COMMAND in gi.nu, which is the only thing that names this path.
#
# Why a file and not a `-c` string: the import and the call are then parsed by
# `nu toolkit.nu check` like any other code, instead of hiding inside a string
# literal that no checker can see and that has to survive nesting in JSON and
# then in a shell command line. The module link is relative, so nothing here
# repeats the absolute path.
#
# Why `def main` and not a bare `$in` at the top level: nu 0.114 fails to
# compile a top-level `$in` in a script ("block is missing compiled
# representation").
use ./gi.nu ["gi check"]

def main []: [string -> any, nothing -> any] {
    $in | gi check
}
