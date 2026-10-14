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
