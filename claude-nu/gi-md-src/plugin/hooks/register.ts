import type { Register } from 'claude-code'

// Mirrors GI_PROTECTED_BRANCHES in gi.nu: the Stop hook enforces the same list.
const PROTECTED_BRANCHES = ['main', 'master']

// `git commit` as the subcommand, after any global options (`git -C dir -c k=v
// commit`); `git log --grep commit` is not one. A quote or `^` may open it:
// agents here run nu one-shots from Bash (`nu --commands '^git commit'`).
const GIT_COMMIT = /(^|[\s;&|('"`^])git(\s+(-[Cc]\s+\S+|--?[\w-]+(=\S+)?))*\s+commit\b/

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

  // Why at the call and not only at the Stop hook: the Stop hook sees the
  // branch when the turn ends, after the commits are made and have to be moved.
  // Why the session's directory and not the repo the command names: it is the
  // repo the Stop hook guards, so the two never disagree about one commit.
  // Why Bash alone: agents here barely use the nushell MCP tool — 4 calls
  // machine-wide in the four weeks before 2026-10-14 (`claude-nu tool-calls`).
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    if (!GIT_COMMIT.test(e.command) || !(await $.env.get('GI_CANVAS'))) {
      return next(e)
    }
    const { exitCode, stdout } = await $.process.run(['git', 'branch', '--show-current'])
    const branch = stdout.trim()
    if (exitCode !== 0 || !PROTECTED_BRANCHES.includes(branch)) {
      return next(e)
    }
    // Why the switch as a command of its own: the branch is read before the
    // command runs, so `git switch --create t && git commit` is refused whole.
    return {
      deny: `You are on \`${branch}\` — gi commits are internal working history and must not land here. First run \`git switch --create <topic>\` as a command of its own, then commit; the branch gets squash-merged into \`${branch}\` after finalization.`,
    }
  }).catch(($, e, next) =>
    // Why deny on a broken guard: a guard that fails open is the one failure
    // nobody sees, as `gi check` turns its own errors into a loud block.
    next.called ? next(e) : { deny: `gi: the branch guard failed (${next.error?.message ?? next.error?.kind}); check the branch before committing.` },
  )
}
