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
