import type { Hook, Register } from 'claude-code'

type Api = Parameters<Hook<'classic.Stop'>>[0]
type StopEvent = Parameters<Hook<'classic.Stop'>>[1]

// Mirrors GI_PROTECTED_BRANCHES in gi.nu: `gi open` warns about the same list.
const PROTECTED_BRANCHES = ['main', 'master']

// The chat budget of the Stop rule: at most this many line breaks, and
// GI_HOOK_MAX_LEN (default 480) UTF-8 bytes, so a Cyrillic answer gets about
// half the letters of a Latin one. Size is the whole floor: a real answer exceeds it.
// Why two lines plus: a status note and a pointer are two, and a floor that
// forbids the second is not measuring the thing it cares about.
// Not a link signal (backtick, `→`, filename) because: it made a path the price
// of every chat line, and demanding a path where there is none teaches the
// agent to invent one.
const MAX_BREAKS = 3
const DEFAULT_MAX_LEN = 480

// The marker that takes one exchange off the canvas, typed by the user at the
// start of their message: `chat: what does this flag do?`.
const CHAT_MARKER = 'chat:'

// The prompt sources that are the user's own words. Why the user's alone: a
// marker the agent or another session could write would lift the floor that
// exists to hold the agent.
const USER_ORIGINS = ['composer', 'bridge', 'sdk']

// `git commit` as the subcommand, after any global options (`git -C dir -c k=v
// commit`); `git log --grep commit` is not one. A quote or `^` may open it:
// agents here run nu one-shots from Bash (`nu --commands '^git commit'`).
const GIT_COMMIT = /(^|[\s;&|('"`^])git(\s+(-[Cc]\s+\S+|--?[\w-]+(=\S+)?))*\s+commit\b/

export const register: Register = on => {
  // Whether the prompt that opened the current turn is a `chat:` aside. Every
  // prompt resets it, so an aside is spent once answered, and a notification or
  // a peer message starting a turn puts the floor back up.
  // Why state here and not the transcript at Stop: `prompt.submit` hands over
  // the text as typed, so nothing parses the session file at every turn end.
  // A reload of the mod clears it: the floor is then up for one turn, and the
  // block's own escape hatch covers that.
  let aside = false

  on('prompt.submit', ($, e, next) => {
    // An absent origin is the user's own prompt, as the engine's types define it.
    const user = !e.isMeta && (!e.origin || USER_ORIGINS.includes(e.origin.kind))
    aside = user && e.text.trim().toLowerCase().startsWith(CHAT_MARKER)
    return next(e)
  })

  // Why a system-prompt section and not `claude --append-system-prompt`: given
  // two of that flag, `claude` keeps only the last, so gi would have to refuse the
  // user's own. A section has its own id and sits beside anyone else's text.
  // Why the line at all: an environment variable is not in the model's context —
  // pointed at $env.GI_CANVAS, the agent guessed its name wrong and went hunting
  // the repo for a canvas.
  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    const canvas = await $.env.get('GI_CANVAS')
    if (!canvas) {
      return composed
    }
    // Relative to the session's directory, as gi prints it and the Stop hook
    // quotes it: the agent stands there, and the absolute form is noise.
    const doc = shortPath(canvas, await $.session.cwd())
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
    const branch = await protectedBranch($)
    if (!branch) {
      return next(e)
    }
    // Why the switch as a command of its own: the branch is read before the
    // command runs, so `git switch --create t && git commit` is refused whole.
    return {
      deny: `You are on \`${branch}\` — gi commits are internal working history and must not land here. First run \`git switch --create <topic>\` as a command of its own, then commit; the branch gets squash-merged into \`${branch}\` after finalization.`,
    }
  }).catch(($, e, next) =>
    // Why deny on a broken guard: a guard that fails open is the one failure
    // nobody sees, as the Stop hook below turns its own errors into a block.
    next.called ? next(e) : { deny: `gi: the branch guard failed (${next.error?.message ?? next.error?.kind}); check the branch before committing.` },
  )

  // The floor under the Canvas style: the style rests on prose and the agent
  // drifts back to long chat answers, so a turn may end only on a short chat
  // line. And a gi turn may not end on main/master: the guard above refuses the
  // commit at the call, this catches what it cannot see — a commit made outside
  // Bash, a merge, a cherry-pick.
  // Why GI_NO_HOOK: `gi open --no-hook` opens a canvas with the style alone, and
  // the mod loads with every launch, so the launch has to say so.
  on('classic.Stop', async ($, e, next) => {
    // Already continuing from a prior block: let the turn end, or a block the
    // agent cannot clear loops forever.
    if (e.stop_hook_active) {
      return next(e)
    }
    const canvas = await $.env.get('GI_CANVAS')
    const reason = !canvas || aside || (await $.env.get('GI_NO_HOOK')) ? undefined : await stopReason($, e, canvas)
    const below = await next(e)
    return reason ? { ...below, block: below.block ? `${below.block}\n\n${reason}` : reason } : below
  }).catch(($, e, next) =>
    // Why block on a broken rule (a typo in GI_HOOK_MAX_LEN, git missing): a
    // failed hook is skipped, and a floor that vanishes is the one failure
    // nobody sees. The loop guard still lets the turn end on the retry.
    e.stop_hook_active || next.called ? next(e) : { block: `gi: the Stop rule failed internally — fix this before continuing: ${next.error?.message ?? next.error?.kind}` },
  )
}

// Why the branch guard before the message rule: even a perfect `done` may not
// end a turn on a protected branch, and the sooner the agent hears it, the
// fewer commits there are to move.
async function stopReason($: Api, e: StopEvent, canvas: string) {
  const branch = await protectedBranch($, e.cwd)
  if (branch) {
    return `You are on \`${branch}\` — gi commits are internal working history and must not land here. Switch to a work branch (\`git switch --create <topic>\`, moving any commits already made); it gets squash-merged into \`${branch}\` after finalization.`
  }
  if (allowed(e.last_assistant_message ?? '', await $.env.get('GI_HOOK_MAX_LEN'))) {
    return undefined
  }
  // The escape hatch is safe by construction: the blocked message is already
  // on the user's screen, and the loop guard ends the turn on the follow-up
  // whatever it says — a misfire can redirect one reply, never trap the agent.
  return `Chat may carry only one short line — \`done\`, a status note, or a pointer to where the answer landed. Move the full answer into \`${shortPath(canvas, e.cwd)}\` and commit it; leave only that one line in chat. If this block looks like a misfire — wrong canvas, no gi work in this session — don't move anything: reply with one short line telling the user to read your previous message above in the chat and to check the session's canvas (\`claude-nu gi\`).`
}

// True when `message` may stand alone in chat: empty, or within both budgets.
function allowed(message: string, maxLen: string | undefined) {
  const text = message.trim()
  const max = maxLen ? Number(maxLen) : DEFAULT_MAX_LEN
  if (!Number.isInteger(max)) {
    throw new Error(`GI_HOOK_MAX_LEN is not an integer: ${maxLen}`)
  }
  return text.split(/\r?\n/).length <= MAX_BREAKS + 1 && new TextEncoder().encode(text).length <= max
}

// The branch of the repo at `dir` (the session's own when omitted) when it is a
// protected one; undefined outside a repo, on a detached HEAD, or on any other.
async function protectedBranch($: Api, dir?: string) {
  const { exitCode, stdout } = await $.process.run(dir ? ['git', '-C', dir, 'branch', '--show-current'] : ['git', 'branch', '--show-current'])
  const branch = stdout.trim()
  return exitCode === 0 && PROTECTED_BRANCHES.includes(branch) ? branch : undefined
}

// The canvas relative to `dir` when it lies under it, as gi prints it: the
// agent stands there, and the absolute form is noise. A canvas above has no
// short form that resolves, so it is named in full.
function shortPath(canvas: string, dir: string) {
  return canvas.startsWith(`${dir}/`) ? canvas.slice(dir.length + 1) : canvas
}
