import { expect, mock, test } from 'claude-code/testing'

import { NAMES, PALETTE, autoName, parseChoice } from '../hooks/core'

test('a session id always picks the same colour, and ids spread over the palette', async () => {
  expect(autoName('4fe72614-ef5d')).toBe(autoName('4fe72614-ef5d'))
  const seen = new Set(Array.from({ length: 200 }, (_, i) => autoName(`session-${i}`)))
  expect(seen.size).toBe(NAMES.length)
  expect(parseChoice(' Teal ')).toBe('teal')
  expect(parseChoice('auto')).toBe('auto')
  expect(parseChoice('mauve')).toBe(null)
})

test('the session colour is drawn above the prompt, on prompts and the spinner, and /color changes it', async ($, on) => {
  mock.store(on)
  on('session.id', async () => ({ value: 'abcdef12-3456' }) as never)
  on('session.start', async (_$, e) => e as never)
  on('command.register', async () => ({ value: {} }) as never)
  on('command.run', async (_$, e) => ({ text: `Session color set to: ${(e as { args: string }).args}` }) as never)
  // Another mod's band beneath this one: the rule goes on top of it.
  on('ui.render', { component: 'AbovePrompt' }, async () => ({ type: 'Text', props: {}, children: ['status band'] }) as never)
  await $.session.start({ source: 'startup', cwd: '/tmp' } as never)

  const auto = PALETTE[autoName('abcdef12-3456')] as string
  const band = { plugin: 'session-tint', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 80 } as never } as const
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...band, surface })
    const drawn = JSON.stringify(await ui.drawn())
    for (const piece of [auto, 'status band']) expect(drawn).toContain(piece)
    // Only the line: no session id beside it.
    expect(drawn).not.toContain('abcdef12')
    await ui.unmount()
  }

  const other = NAMES.find(n => PALETTE[n] !== auto && n !== 'teal') as string
  const said = await $.command.run({ command: 'color', args: other, origin: { kind: 'composer' } } as never)
  expect(JSON.stringify(said)).toContain(`set to: ${other}`)

  const row = await $.ui.mount({
    plugin: 'session-tint',
    surface: 'desktop',
    component: 'UserMessage',
    // As the desktop app hands a prompt over: the SDK host's turn, always expanded.
    props: { text: 'hello there', origin: { kind: 'sdk' }, isExpanded: true } as never,
  })
  const drawnRow = JSON.stringify(await row.drawn())
  expect(drawnRow).toContain('hello there')
  expect(drawnRow).toContain('flex-end')
  // In a card outlined in the session's colour.
  expect(drawnRow).toContain('"borderStyle":"round"')
  expect(drawnRow).toContain(PALETTE[other] as string)
  await row.unmount()

  const spin = await $.ui.mount({
    plugin: 'session-tint',
    surface: 'terminal',
    component: 'Spinner',
    props: { word: 'Baking', message: '', suffix: '…', mode: 'thinking' } as never,
  })
  expect(JSON.stringify(await spin.drawn())).toContain('● Baking…')
  await spin.unmount()
})
