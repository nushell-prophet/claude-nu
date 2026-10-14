import type { Register } from 'claude-code'

// Why a system-prompt section and not `claude --append-system-prompt`: given
// two of that flag, `claude` keeps only the last, so gi would have to refuse the
// user's own. A section has its own id and sits beside anyone else's text.
// Why the line at all: an environment variable is not in the model's context —
// pointed at $env.GI_CANVAS, the agent guessed its name wrong and went hunting
// the repo for a canvas.
export const register: Register = on => {
  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    const canvas = await $.env.get('GI_CANVAS')
    if (!canvas) {
      return composed
    }
    // Relative to the session's directory, as gi prints it and the Stop hook
    // quotes it: the agent stands there, and the absolute form is noise.
    const cwd = await $.session.cwd()
    const doc = canvas.startsWith(`${cwd}/`) ? canvas.slice(cwd.length + 1) : canvas
    const text = `This session's canvas is \`${doc}\` — the one file the Canvas output style is about. Read it before your first answer; do not search for it.`
    return { ...composed, sections: [...composed.sections, { id: 'gi:canvas', text, scope: 'session' }] }
  })
}
