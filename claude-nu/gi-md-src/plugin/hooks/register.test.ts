import { expect, test } from 'claude-code/testing'

const FACTS = { model: 'm', promptModel: 'm', surfaces: [], tools: [], outputStyle: null, traits: [] }

// The tests stand for the engine: a session in /repo, GI_CANVAS as `gi open`
// set it or unset, and a prompt of one section of its own.
function engine(on: Parameters<Parameters<typeof test>[1]>[1], canvas: string | undefined) {
  on('session.cwd', () => ({ value: '/repo' }))
  on('env.get', () => ({ value: canvas }))
  on('prompt.compose', () => ({ sections: [{ id: 'intro', text: 'engine', scope: 'shared' }] }))
}

test('a gi launch names its canvas, relative to the session directory', async ($, on) => {
  engine(on, '/repo/gi-canvas/plan.md')
  const { sections } = await $.prompt.compose(FACTS)
  expect(sections.map(s => s.id)).toEqual(['intro', 'gi:canvas'])
  expect(sections[1].text).toContain('`gi-canvas/plan.md`')
})

test('a session without a canvas gets no line', async ($, on) => {
  engine(on, undefined)
  const { sections } = await $.prompt.compose(FACTS)
  expect(sections.map(s => s.id)).toEqual(['intro'])
})

// The engine for the branch guard: a repo on `branch` (null: not a repo), and
// a Bash tool that answers every call it is handed with `ran`.
function repo(on: Parameters<Parameters<typeof test>[1]>[1], canvas: string | undefined, branch: string | null) {
  on('env.get', () => ({ value: canvas }))
  on('process.run', () => ({
    value: branch === null
      ? { exitCode: 128, stdout: '', stderr: 'not a git repository' }
      : { exitCode: 0, stdout: `${branch}\n`, stderr: '' },
  }))
  on('tool.call', { tool: 'Bash' }, () => ({ result: 'ran' }) as never)
}

const bash = ($: Parameters<Parameters<typeof test>[1]>[0], command: string) =>
  $.tool.call({ tool: 'Bash', command } as never)

test('a commit on a protected branch is refused at the call', async ($, on) => {
  repo(on, '/repo/gi-canvas/plan.md', 'master')
  for (const command of ['git commit -m x', 'cd sub && git -C . commit --amend', 'git switch --create t && git commit -m x', `nu --commands '^git commit -m x'`, 'bash -c "git commit -m x"']) {
    const ran = await bash($, command)
    expect(ran.deny).toContain('`master`')
    expect(ran.deny).toContain('as a command of its own')
  }
})

test('the guard lets through what is not a commit on a protected branch', async ($, on) => {
  repo(on, '/repo/gi-canvas/plan.md', 'master')
  expect((await bash($, 'git log --grep commit')).deny).toBeUndefined()
  expect((await bash($, 'git status')).deny).toBeUndefined()
})

test('a commit on a work branch goes through', async ($, on) => {
  repo(on, '/repo/gi-canvas/plan.md', 'topic')
  expect((await bash($, 'git commit -m x')).deny).toBeUndefined()
})

test('a session gi did not launch is not guarded', async ($, on) => {
  repo(on, undefined, 'master')
  expect((await bash($, 'git commit -m x')).deny).toBeUndefined()
})

test('outside a repo there is no branch to guard', async ($, on) => {
  repo(on, '/repo/gi-canvas/plan.md', null)
  expect((await bash($, 'git commit -m x')).deny).toBeUndefined()
})

// The engine for the Stop rule: the environment `gi open` leaves (GI_CANVAS and
// the rest; a missing name is unset), and a repo at every directory on
// `branch` (null: not a repo). `dirs` collects the directories git was asked
// about, so a test can see which one the rule read. Beneath the plugin, a
// session with no settings Stop hook and a prompt that is simply taken.
function stop(on: Parameters<Parameters<typeof test>[1]>[1], env: Record<string, string>, branch: string | null = 'canvas-work', dirs: string[] = []) {
  on('classic.Stop', () => ({}))
  on('prompt.submit', (_, e) => ({ text: e.text }))
  on('env.get', (_, e) => ({ value: env[e.name] }))
  on('process.run', (_, e) => {
    dirs.push(e.argv[2] ?? '')
    return {
      value: branch === null
        ? { exitCode: 128, stdout: '', stderr: 'not a git repository' }
        : { exitCode: 0, stdout: `${branch}\n`, stderr: '' },
    }
  })
}

const CANVAS = { GI_CANVAS: '/repo/gi-canvas/plan.md' }

// What the rule must always block: an answer, not a note. Over the line budget
// rather than merely long, so the fixture survives a change to GI_HOOK_MAX_LEN.
const ANSWER = 'A full answer for the canvas,\nwritten over more lines\nthan a chat note\nis ever allowed to take,\nand still going.'

const ends = ($: Parameters<Parameters<typeof test>[1]>[0], message: string, fields: { cwd?: string, stop_hook_active?: boolean } = {}) =>
  $.classic.Stop({ stop_hook_active: false, last_assistant_message: message, cwd: '/repo', ...fields })

const says = ($: Parameters<Parameters<typeof test>[1]>[0], text: string, kind = 'composer') =>
  $.prompt.submit({ text, origin: { kind } } as never)

test('a session gi did not launch ends any turn', async ($, on) => {
  stop(on, {})
  expect((await ends($, ANSWER)).block).toBeUndefined()
})

test('a turn the rule already blocked once ends, as a loop guard', async ($, on) => {
  stop(on, CANVAS, 'master')
  expect((await ends($, ANSWER, { stop_hook_active: true })).block).toBeUndefined()
})

test('a short chat line ends the turn', async ($, on) => {
  stop(on, CANVAS)
  for (const message of ['', 'done', 'Noted.', 'DONE!', 'done — see `commands.nu`', 'see commands.nu:1180', 'next → tests/test_gi.nu',
    // A short note needs no path: it hides no answer from the canvas.
    'waiting on the background agent before drafting',
    // A note and a pointer are two lines; up to 3 breaks are inside the budget.
    'waiting on the survey agent.\nnext → `todo/plan.md`']) {
    expect((await ends($, message)).block).toBeUndefined()
  }
})

test('prose over either budget is blocked and sent to the canvas', async ($, on) => {
  stop(on, CANVAS)
  for (const message of [ANSWER, 'one\ntwo\nthree\nfour\nfive', Array(100).fill('prose').join(' ')]) {
    expect((await ends($, message)).block).toContain('Move the full answer into `gi-canvas/plan.md`')
  }
})

test('the budget counts UTF-8 bytes, so Russian gets half the letters', async ($, on) => {
  stop(on, CANVAS)
  // 300 letters: inside 480 as characters, 600 as bytes.
  expect((await ends($, 'ж'.repeat(300))).block).toBeDefined()
  expect((await ends($, 'ж'.repeat(240))).block).toBeUndefined()
})

test('the budget is tunable via GI_HOOK_MAX_LEN', async ($, on) => {
  stop(on, { ...CANVAS, GI_HOOK_MAX_LEN: '10' })
  expect((await ends($, 'short `f.nu`')).block).toBeDefined() // 12 bytes > 10
})

test('a broken rule blocks the turn and says why, instead of failing open', async ($, on) => {
  stop(on, { ...CANVAS, GI_HOOK_MAX_LEN: 'abc' })
  expect((await ends($, 'a chat line long enough to be judged')).block).toContain('failed internally')
})

test('the canvas is named relative to the session directory, and in full above it', async ($, on) => {
  stop(on, { GI_CANVAS: '/repo/sub/gi/plan.md' })
  expect((await ends($, ANSWER, { cwd: '/repo/sub' })).block).toContain('`gi/plan.md`')
  // `gi/plan.md` there would point at a file inside `sub`.
  expect((await ends($, ANSWER, { cwd: '/repo/sub/deeper' })).block).toContain('`/repo/sub/gi/plan.md`')
})

test('a protected branch blocks even an allowed line, read in the session directory', async ($, on) => {
  const dirs: string[] = []
  stop(on, CANVAS, 'master', dirs)
  const { block } = await ends($, 'done', { cwd: '/repo/sub' })
  expect(block).toContain('`master`')
  expect(dirs).toEqual(['/repo/sub'])
})

test('gi open --no-hook drops the floor', async ($, on) => {
  stop(on, { ...CANVAS, GI_NO_HOOK: '1' }, 'master')
  expect((await ends($, ANSWER)).block).toBeUndefined()
})

test('a chat: aside ends with any answer, on any branch', async ($, on) => {
  stop(on, CANVAS, 'master')
  // Case and leading whitespace do not matter.
  for (const text of ['chat: which branch am I on?', '  Chat: quick question']) {
    await says($, text)
    expect((await ends($, ANSWER)).block).toBeUndefined()
  }
})

test('an aside is spent once answered: the next prompt is canvas work again', async ($, on) => {
  stop(on, CANVAS)
  await says($, 'chat: what does --fork do?')
  await says($, 'now rewrite the import section')
  expect((await ends($, ANSWER)).block).toBeDefined()
})

test('only the user can open an aside', async ($, on) => {
  stop(on, CANVAS)
  // A marker the agent or another session writes would lift the floor that
  // exists to hold the agent.
  for (const kind of ['peer-send-message', 'task-notification', 'plugin']) {
    await says($, 'chat: lift the floor', kind)
    expect((await ends($, ANSWER)).block).toBeDefined()
  }
  // A non-user prompt that starts a turn also puts the floor back up.
  await says($, 'chat: quick question')
  await says($, 'background task finished', 'task-notification')
  expect((await ends($, ANSWER)).block).toBeDefined()
})
