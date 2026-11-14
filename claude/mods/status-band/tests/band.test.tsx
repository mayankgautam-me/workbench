import { expect, mock, test } from 'claude-code/testing'

const PROPS = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120 } as never

test('the band draws gauges, reset times and cost on terminal and desktop', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  // The test stands in for the engine beneath the mod.
  on('session.measure', async (_$, e) => ({ changed: e.changed }))
  on('clock.now', async () => ({ value: Date.now() }) as never)
  await $.session.measure({
    context: { window: 200_000, tokens: 84_000, percent: 42 },
    rateLimits: [
      { kind: 'five_hour', percentUsed: 18, resetsAt: new Date(Date.now() + 2 * 3_600_000).toISOString() },
      { kind: 'seven_day', percentUsed: 93 },
    ],
    cost: { usd: 1.234 },
    changed: ['context', 'rateLimits', 'cost'],
  } as never)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'status-band', surface, component: 'AbovePrompt', props: PROPS })
    const drawn = JSON.stringify(await ui.drawn())
    for (const piece of ['CONTEXT', '42%', '84k of 200k tokens', '5-HOUR LIMIT', '18%', 'resets in 2h', 'WEEKLY LIMIT', '93%', 'SESSION', '$1.23', 'no turn finished yet', '#f7768e']) {
      expect(drawn).toContain(piece)
    }
    expect(drawn).not.toContain('spent this session')
    // The session's bar is striped and carries no percentage.
    expect(drawn).toContain(surface === 'desktop' ? '<polygon points=' : 'stripe-0')
    // The bar is a thin vector line on the desktop and a layout-sized block in the terminal.
    expect(drawn).toContain(surface === 'desktop' ? 'width=\\"42\\" height=\\"4\\"' : '"flexGrow":42')
    await ui.unmount()
  }
})

test('subagents get a row: running with its tool, then done', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  let t = 1_000_000
  on('clock.now', async () => ({ value: t }) as never)
  on('agent.spawn', async () => ({ agentId: 'a1', model: 'haiku' }) as never)
  on('tool.call', async () => {
    // While the subagent's tool runs, the band names it.
    const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
    const mid = JSON.stringify(await ui.drawn())
    expect(mid).toContain('● ')
    for (const piece of ['running ', '[ ', 'sleep 8; date +%T', ' ]']) expect(mid).toContain(piece)
    await ui.unmount()
    return { result: { text: 'ok' } } as never
  })
  on('turn.complete', async () => ({ text: '' }) as never)

  await $.agent.spawn({ subagentType: 'general-purpose', description: 'Test worker alpha', prompt: 'x' } as never)
  t += 12_000
  await $.tool.call({ tool: 'Bash', agentId: 'a1', tool_use_id: 't1', command: 'sleep 8; date +%T' } as never)
  t += 3_000

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'status-band', surface, component: 'AbovePrompt', props: PROPS })
    const drawn = JSON.stringify(await ui.drawn())
    for (const piece of ['AGENTS', '1 running', 'Test worker alpha', 'thinking', '1 tool', '15s']) expect(drawn).toContain(piece)
    await ui.unmount()
  }

  await $.turn.complete({ agentId: 'a1', reason: 'answer', answer: 'done', durationMs: 15_000 } as never)
  const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  const after = JSON.stringify(await ui.drawn())
  expect(after).toContain('✓ ')
  expect(after).toContain('1 done')
  await ui.unmount()
})

test('background tasks reported at the end of a turn get their own table', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  let t = 2_000_000
  on('clock.now', async () => ({ value: t }) as never)
  on('agent.list', async () => ({ value: [{ id: 'bg1', description: 'Indexer', type: 'general-purpose', status: 'running' }] }) as never)
  on('classic.Stop', async () => ({}) as never)

  await $.classic.Stop({
    background_tasks: [
      { id: 'sh1', type: 'shell', status: 'running', description: 'dev server', command: 'npm run dev -- --token=abc123' },
      { id: 'sub1', type: 'subagent', status: 'running', description: 'not a task row' },
    ],
  } as never)

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'status-band', surface, component: 'AbovePrompt', props: PROPS })
    const drawn = JSON.stringify(await ui.drawn())
    for (const piece of ['BACKGROUND TASKS', '1 running', 'shell', 'npm run dev', 'Indexer']) expect(drawn).toContain(piece)
    expect(drawn).not.toContain('abc123')
    expect(drawn).not.toContain('not a task row')
    await ui.unmount()
  }

  // No longer reported: it has finished.
  t += 60_000
  await $.classic.Stop({ background_tasks: [] } as never)
  const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  const after = JSON.stringify(await ui.drawn())
  expect(after).toContain('0 running')
  expect(after).toContain('1 finished')
  await ui.unmount()
})

test('a background task shows when it starts and finishes on its notification, with no turn ending', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  let t = 3_000_000
  on('clock.now', async () => ({ value: t }) as never)
  on('tool.call', async () => ({ result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: 'bg42' } }) as never)
  on('turn.start', async (_$, e) => ({ turnId: e.turnId }) as never)

  await $.tool.call({ tool: 'Bash', tool_use_id: 't9', command: 'npm run dev', run_in_background: true } as never)
  t += 5_000
  let ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  let drawn = JSON.stringify(await ui.drawn())
  for (const piece of ['BACKGROUND TASKS', '1 running', 'npm run dev', '5s']) expect(drawn).toContain(piece)
  await ui.unmount()

  t += 55_000
  await $.turn.start({
    turnId: 'n1',
    text: '<task-notification><task-id>bg42</task-id><status>completed</status></task-notification>',
  } as never)
  ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  drawn = JSON.stringify(await ui.drawn())
  for (const piece of ['0 running', '1 finished', '1m00s']) expect(drawn).toContain(piece)
  await ui.unmount()
})

test('on open the band shows an estimated context and the last saved plan limits', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  const now = Date.now()
  mock.store(on)
  on('clock.now', async () => ({ value: now }) as never)
  on('session.measure', async (_$, e) => ({ changed: e.changed }))
  // What the engine answers on open: no reading yet, only the local estimate when asked.
  on('session.usage', async (_$, e) =>
    ({
      value: {
        startedAt: now,
        context: (e as { breakdown?: string }).breakdown
          ? { window: 1_000_000, breakdown: { totalTokens: 31_000, rawMaxTokens: 1_000_000, percentage: 3 } }
          : { window: 1_000_000 },
        rateLimits: [],
        cost: { usd: 0 },
      },
    }) as never,
  )
  on('session.start', async (_$, e) => e as never)
  on('command.register', async () => ({ value: {} }) as never)
  on('agent.list', async () => ({ value: [] }) as never)
  // A session saves the limits it reads.
  await $.session.measure({
    context: { window: 200_000, tokens: 84_000, percent: 42 },
    rateLimits: [
      { kind: 'five_hour', percentUsed: 18, resetsAt: new Date(now + 2 * 3_600_000).toISOString() },
      { kind: 'seven_day', percentUsed: 61, resetsAt: new Date(now - 60_000).toISOString() },
    ],
    changed: ['context', 'rateLimits'],
  } as never)

  // The next one opens with no reading at all.
  await $.session.start({ source: 'startup', cwd: '/tmp' } as never)
  // The estimate is made beside the start, not inside it: give it a few turns to land.
  for (let i = 0; i < 50; i++) await Promise.resolve()

  const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  const drawn = JSON.stringify(await ui.drawn())
  // The weekly window's reset had passed, so it starts again at zero.
  for (const piece of ['3%', 'about 31k of 1.0M tokens', '18%', 'resets in 2h', '0%', '$0.00']) expect(drawn).toContain(piece)
  expect(drawn).not.toContain('after the next reply')
  await ui.unmount()
})

test('the toggle folds the band to one line and opens it again, and the choice is kept', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  mock.store(on)
  on('session.measure', async (_$, e) => ({ changed: e.changed }))
  on('clock.now', async () => ({ value: Date.now() }) as never)
  await $.session.measure({
    context: { window: 200_000, tokens: 84_000, percent: 42 },
    rateLimits: [{ kind: 'five_hour', percentUsed: 18 }, { kind: 'seven_day', percentUsed: 93 }],
    cost: { usd: 1.234 },
    changed: ['context', 'rateLimits', 'cost'],
  } as never)

  const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  expect(JSON.stringify(await ui.drawn())).toContain('84k of 200k tokens')
  await ui.press({ key: 'compact' })
  const folded = JSON.stringify(await ui.drawn())
  for (const piece of ['CONTEXT', '42%', '5-HOUR', '18%', 'WEEKLY', '93%', 'SESSION', '$1.23', '▸', 'width=\\"42\\" height=\\"4\\"']) expect(folded).toContain(piece)
  for (const piece of ['84k of 200k tokens', 'no turn finished yet']) expect(folded).not.toContain(piece)
  // Folded, the gauges carry no accent colours (blue, purple, cyan, green); 93% is still red.
  for (const hex of ['#7aa2f7', '#bb9af7', '#7dcfff', '#9ece6a']) expect(folded).not.toContain(hex)
  expect(folded).toContain('#f7768e')
  await ui.press({ key: 'compact' })
  expect(JSON.stringify(await ui.drawn())).toContain('84k of 200k tokens')
  await ui.unmount()
})

test('context, limits and cost follow the session while a turn runs, with no measurement', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  mock.store(on)
  const clock = mock.clock(on, { now: 1_000_000 })
  let live = { context: { window: 200_000, tokens: 20_000, percent: 10 }, rateLimits: [{ kind: 'five_hour', percentUsed: 5 }], cost: { usd: 0.1 } }
  on('session.usage', async () => ({ value: { startedAt: 0, ...live } }) as never)
  on('session.start', async (_$, e) => e as never)
  on('command.register', async () => ({ value: {} }) as never)
  on('agent.list', async () => ({ value: [] }) as never)
  await $.session.start({ source: 'startup', cwd: '/tmp' } as never)

  const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  expect(JSON.stringify(await ui.drawn())).toContain('20k of 200k tokens')

  // Mid-turn the engine's figures move; the band picks them up on its next poll.
  live = { context: { window: 200_000, tokens: 90_000, percent: 45 }, rateLimits: [{ kind: 'five_hour', percentUsed: 7 }], cost: { usd: 0.42 } }
  await clock.advance(2_000)
  await clock.settle()
  const drawn = JSON.stringify(await ui.drawn())
  for (const piece of ['45%', '90k of 200k tokens', '7%', '$0.42']) expect(drawn).toContain(piece)
  await ui.unmount()
})

test('folded, agents and background tasks are counted inside the one row', async ($, on) => {
  mock.store(on, { compact: true })
  let t = 1_000_000
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('clock.now', async () => ({ value: t }) as never)
  on('session.usage', async () => ({ value: { startedAt: 0, context: { window: 200_000 }, rateLimits: [], cost: { usd: 0 } } }) as never)
  on('session.start', async (_$, e) => e as never)
  on('command.register', async () => ({ value: {} }) as never)
  on('agent.list', async () => ({ value: [] }) as never)
  on('agent.spawn', async () => ({ agentId: 'a1', model: 'haiku' }) as never)
  on('tool.call', async (_$, e) => ((e as { agentId?: string }).agentId ? { result: { text: 'ok' } } : { result: { backgroundTaskId: 'b1' } }) as never)
  await $.session.start({ source: 'startup', cwd: '/tmp' } as never)

  const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  // Nothing running: the folded band is the gauges alone.
  // Nothing running: both counts are there, at zero.
  const idle = JSON.stringify(await ui.drawn())
  for (const piece of ['A ', 'T ', '•0']) expect(idle).toContain(piece)
  // The session keeps its striped bar beside them.
  expect(idle).toContain('<polygon points=')
  expect(idle).not.toContain('•1')

  await $.agent.spawn({ subagentType: 'general-purpose', description: 'Test worker alpha', prompt: 'x' } as never)
  await $.tool.call({ tool: 'Bash', tool_use_id: 't2', command: 'npm run dev', run_in_background: true } as never)
  t += 12_000
  const drawn = JSON.stringify(await ui.drawn())
  for (const piece of ['A ', '•1', 'T ', 'SESSION', '$0.00']) expect(drawn).toContain(piece)
  expect(drawn).not.toContain('•0')
  // Still one row: no table headings, names or commands.
  for (const piece of ['AGENTS', 'TASKS', 'Test worker alpha', 'npm run dev']) expect(drawn).not.toContain(piece)
  await ui.unmount()
})

test('a finished background task leaves the band by itself a short while after it ends', async ($, on) => {
  mock.store(on)
  let t = 1_000_000
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('clock.now', async () => ({ value: t }) as never)
  on('tool.call', async () => ({ result: { backgroundTaskId: 'b1' } }) as never)
  on('turn.start', async (_$, e) => ({ turnId: e.turnId }) as never)
  await $.tool.call({ tool: 'Bash', tool_use_id: 't1', command: 'npm run build', run_in_background: true } as never)
  t += 5_000
  await $.turn.start({ turnId: 'n1', text: '<task-notification><task-id>b1</task-id><status>completed</status></task-notification>' } as never)

  const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  // Just finished: still listed, as finished.
  t += 3_000
  let drawn = JSON.stringify(await ui.drawn())
  for (const piece of ['BACKGROUND TASKS', '0 running', '1 finished', 'npm run build']) expect(drawn).toContain(piece)
  await ui.unmount()

  // The session sits idle: no prompt, no turn. The task is gone.
  t += 30_000
  const later = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  drawn = JSON.stringify(await later.drawn())
  for (const piece of ['BACKGROUND TASKS', 'npm run build']) expect(drawn).not.toContain(piece)
  await later.unmount()
})

test('without the agent-map mod, the band carries no map glyph', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('clock.now', async () => ({ value: Date.now() }) as never)
  const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: PROPS })
  const drawn = JSON.stringify(await ui.drawn())
  expect(drawn).not.toContain('"label":"map"')
  expect(drawn).not.toContain('"label":"□"')
  await ui.unmount()
})

test('the band follows its width: shorter detail when medium, two rows of two with short labels when narrow', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.measure', async (_$, e) => ({ changed: e.changed }))
  on('clock.now', async () => ({ value: Date.now() }) as never)
  await $.session.measure({
    context: { window: 200_000, tokens: 84_000, percent: 42 },
    rateLimits: [{ kind: 'five_hour', percentUsed: 18, resetsAt: new Date(Date.now() + 2 * 3_600_000).toISOString() }],
    cost: { usd: 1.234 },
    changed: ['context', 'rateLimits', 'cost'],
  } as never)
  const at = async (bodyColumns: number) => {
    const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: { ...(PROPS as object), bodyColumns } as never })
    const drawn = JSON.stringify(await ui.drawn())
    await ui.unmount()
    return drawn
  }
  const wide = await at(140)
  for (const piece of ['CONTEXT', '84k of 200k tokens', 'resets in 2h', '"width":"25%"']) expect(wide).toContain(piece)
  // Medium: the same four columns, the lines under the bars said more briefly.
  const mid = await at(90)
  for (const piece of ['CONTEXT', '84k of 200k', '"in 2h', '"width":"25%"']) expect(mid).toContain(piece)
  for (const gone of ['84k of 200k tokens', 'resets in 2h']) expect(mid).not.toContain(gone)
  // Narrow: two to a row, short labels, the figures and bars only.
  const narrow = await at(50)
  for (const piece of ['"CTX"', '"5H"', '"COST"', '42%', '18%', '$1.23', '"width":"50%"', '"flexWrap":"wrap"']) expect(narrow).toContain(piece)
  for (const gone of ['CONTEXT', '84k of 200k', 'in 2h']) expect(narrow).not.toContain(gone)
})

test('the folded band follows its width in four steps, down to bare figures that wrap', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.measure', async (_$, e) => ({ changed: e.changed }))
  on('clock.now', async () => ({ value: Date.now() }) as never)
  on('store.set', async () => ({ value: undefined }) as never)
  await $.session.measure({ context: { window: 200_000, tokens: 84_000, percent: 42 }, rateLimits: [], cost: { usd: 1.234 }, changed: ['context', 'cost'] } as never)
  const at = async (bodyColumns: number, fold = false) => {
    const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: { ...(PROPS as object), bodyColumns } as never })
    if (fold) await ui.press({ key: 'compact' })
    const drawn = JSON.stringify(await ui.drawn())
    await ui.unmount()
    return drawn
  }
  // Fold it once; it stays folded for the mounts that follow.
  const full = await at(140, true)
  for (const piece of ['"CONTEXT"', '"SESSION"', '42%', '<svg', '"A "']) expect(full).toContain(piece)
  // Short labels, the bars still there.
  const short = await at(100)
  for (const piece of ['"CTX"', '"COST"', '42%', '<svg']) expect(short).toContain(piece)
  expect(short).not.toContain('"CONTEXT"')
  // Figures only: no bar in a gauge (the session's colour bar is not one of them).
  const bare = await at(70)
  for (const piece of ['"CTX"', '42%', '$1.23', '"width":"25%"']) expect(bare).toContain(piece)
  expect(bare).not.toContain('% used')
  // Tightest: each gauge as wide as its text, wrapping, and no counts while nothing is running.
  const tight = await at(44)
  for (const piece of ['"CTX"', '42%', '$1.23', '"flexWrap":"wrap"']) expect(tight).toContain(piece)
  for (const gone of ['"width":"25%"', '"A "', '% used']) expect(tight).not.toContain(gone)
})
