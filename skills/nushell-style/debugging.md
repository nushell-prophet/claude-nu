# Debugging with `--ide-check`

Use `nu --ide-check` for static analysis—outputs structured JSON diagnostics with precise spans.

## What It Catches

| Error Type | Detected? | Example Message |
|------------|-----------|-----------------|
| Undefined variable | ✅ | `Variable not found.` |
| Type mismatch | ✅ | `Type mismatch.` |
| Missing argument | ✅ | `Missing required positional argument.` |
| Wrong flag | ✅ | `Command doesn't have flag X` |
| Pipeline type error | ✅ | `Command does not support string input.` |
| Unclosed delimiters | ✅ | `Unclosed delimiter.` |
| Unknown command | ❌ | Runtime only (could be external) |

## Parsing Diagnostics

```nushell
def diagnose [file: path] {
    let content = open $file
    nu --ide-check 10 $file | lines | each { from json }
    | where type == "diagnostic"
    | each {|d|
        let before = $content | str substring 0..$d.span.start
        let line = ($before | split row "\n" | length)
        {
            severity: $d.severity,
            message: $d.message,
            line: $line,
            code: ($content | str substring $d.span.start..$d.span.end)
        }
    }
}
```

## Agent Workflow

1. Run `--ide-check` first (catches static errors)
2. If no errors, run the file for runtime errors
3. Parse spans to get exact line numbers and code snippets
