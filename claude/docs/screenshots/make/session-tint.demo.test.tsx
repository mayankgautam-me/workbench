import { mock, test } from 'claude-code/testing'

test('demo', async ($, on) => {
  mock.store(on)
  on('session.id', async () => ({ value: 'abcdef12-3456' }) as never)
  on('session.start', async (_$, e) => e as never)
  on('command.register', async () => ({ value: {} }) as never)
  on('command.run', async (_$, e) => ({ text: `Session color set to: ${(e as { args: string }).args}` }) as never)
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  await $.session.start({ source: 'startup', cwd: '/tmp' } as never)
  const say = (name: string, tree: unknown) => console.log(`DEMO ${name} ${JSON.stringify(tree)}`)
  const part = async (name: string, component: string, props: unknown) => {
    const ui = await $.ui.mount({ plugin: 'session-tint', surface: 'desktop', component, props } as never)
    say(name, await ui.drawn())
    await ui.unmount()
  }
  for (const [color, prompt, word] of [['purple', 'add rate limits to the telemetry endpoint', 'Reading'], ['teal', 'why does the gateway drop the first packet after waking?', 'Thinking'], ['orange', 'bump the firmware version and tag the release', 'Tagging']] as const) {
    await $.command.run({ command: 'tint', args: color, origin: { kind: 'composer' } } as never)
    await part(`tint-${color}-prompt`, 'UserMessage', { text: prompt, origin: { kind: 'sdk' }, isExpanded: true })
    await part(`tint-${color}-spinner`, 'Spinner', { word, message: '', suffix: '…', mode: 'thinking' })
    await part(`tint-${color}-done`, 'TurnDuration', { word: 'Worked', durationMs: 94_000 })
    await part(`tint-${color}-rule`, 'AbovePrompt', { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 100 })
  }
})
