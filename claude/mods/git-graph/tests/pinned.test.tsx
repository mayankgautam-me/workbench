import { expect, test } from 'claude-code/testing'

const hash = (i: number) => i.toString(16).padStart(40, '0')
// A docked panel 40 rows tall: the window the toolbar stays at the top of.
const BODY_ROWS = 40
const paneProps = (bodyRows: number) => ({ title: 'Git graph', isFocused: false, bodyColumns: 120, placement: 'dock', scroll: { offset: 0, bodyRows } }) as never
// The person's wheel over the panel: `by` rows, negative toward the top.
const wheel = (by: number) => ({ component: 'Pane', requestId: 'git-graph', offset: 0, by, bodyRows: BODY_ROWS, contentRows: BODY_ROWS, origin: { kind: 'person' } }) as never

// The engine draws nothing of a panel over 100,000 characters and says "nothing to show yet".
test('a long history scrolls under the toolbar, the whole of it, each drawing within what a panel may hold', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  // Beneath the mod, the engine's own move of the panel's window: every tick puts it back on the
  // middle slack row, so it can move both ways and the next tick, up or down, reaches the mod.
  const parkedAt: number[] = []
  on('ui.scroll', async (_$, e) => (parkedAt.push((e as { offset: number }).offset), { value: {} }) as never)
  // 150 commits and one more: every third a merge, so several lines run side by side.
  const LOG = Array.from({ length: 151 }, (_, i) => `${hash(i + 1)}\x1f${hash(i + 2)}${i % 3 === 0 ? ` ${hash(i + 5)}` : ''}\x1fA long author name\x1f${1700000000 - i}\x1fA commit subject of the usual length, about this long ${i}\x1e`).join('\n')
  const asked: string[][] = []
  on('process.run', async (_$, e) => {
    const argv = ((e as { argv?: string[] }).argv ?? []).slice(3)
    asked.push(argv)
    const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never
    const no = { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
    if (argv[0] === 'rev-parse' && argv[1] === '--show-toplevel') return ok('/p\n')
    if (argv[0] === 'rev-parse' && argv[1] === 'HEAD') return ok(`${hash(1)}\n`)
    if (argv[0] === 'log' && argv[1] === '-1') return ok('A subject\n\n\tindented\r\nwith \x1b[31mcolour\x1b[0m\n')
    if (argv[0] === 'log') {
      // As git does: no more than the limit asked for.
      const n = Number(argv[argv.indexOf('-n') + 1])
      return ok(LOG.split('\n').slice(0, n).join('\n'))
    }
    if (argv[0] === 'symbolic-ref') return ok('main\n')
    return no
  })
  await $.command.run({ command: 'graph' } as never)
  const subject = (i: number) => `about this long ${i}"`

  for (const surface of ['desktop', 'terminal'] as const) {
    const ui = await $.ui.mount({ plugin: 'git-graph', surface, component: 'Pane', requestId: 'git-graph', props: paneProps(BODY_ROWS) })
    const first = JSON.stringify(await ui.drawn())
    // The drawing is two rows taller than the window, the panel itself as tall as the window: the
    // app hands the panel its wheel only while its window can move that way.
    expect(first.startsWith(`{"type":"Box","props":{"flexDirection":"column","width":"100%","height":${BODY_ROWS + 2},"flexShrink":0}`)).toBe(true)
    expect(first).toContain(`"height":${BODY_ROWS},`)
    expect(first.length).toBeLessThan(95000)
    expect(first).toContain(subject(0))
    expect(first).not.toContain(subject(100))
    // No paging: no buttons for it and no count.
    expect(first).not.toContain('newer commits')
    expect(first).not.toContain('"more"')
    expect(first).not.toContain(' of 150')
    // The tree is exactly as tall as the window, so the panel's own window has nothing to move.
    expect(first).toContain(`"height":${BODY_ROWS}`)

    // The wheel, a few rows at a time, reaches the oldest commit; on the way the next commits are
    // read from git without a press, and every drawing has the toolbar and stays within bounds.
    const seen = new Set<number>()
    let ticks = 0
    let drawing = first
    while (!drawing.includes('the oldest commit') && ticks < 200) {
      await $.ui.scroll(wheel(3))
      drawing = JSON.stringify(await ui.drawn())
      expect(drawing.length).toBeLessThan(95000)
      expect(await ui.find({ key: 'refresh' })).toBeDefined()
      expect(await ui.find({ key: 'columns' })).toBeDefined()
      for (let i = 0; i <= 150; i++) if (drawing.includes(subject(i))) seen.add(i)
      ticks += 1
    }
    expect(drawing).toContain('the oldest commit')
    expect(drawing).toContain(subject(150))
    // Every commit came into view on the way down.
    for (let i = 0; i <= 150; i++) if (!seen.has(i) && !first.includes(subject(i))) throw new Error(`commit ${i} was never drawn`)
    expect(asked.some(a => a[0] === 'log' && a.includes('301'))).toBe(true)

    // Back up to the newest, the toolbar still there.
    for (let i = 0; i < 200 && !JSON.stringify(await ui.drawn()).includes(subject(0)); i++) await $.ui.scroll(wheel(-5))
    const back = JSON.stringify(await ui.drawn())
    expect(back).toContain(subject(0))
    expect(await ui.find({ key: 'refresh' })).toBeDefined()
    await ui.unmount()
  }
  expect(parkedAt.length).toBeGreaterThan(0)
  expect(parkedAt.every(offset => offset === 1)).toBe(true)
})

test('a selected row is scrolled through a line at a time, and what git says is drawn without its control characters', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  on('ui.scroll', async () => ({ value: {} }) as never)
  const LOG = Array.from({ length: 60 }, (_, i) => `${hash(i + 1)}\x1f${hash(i + 2)}\x1fAn author\x1f${1700000000 - i}\x1fSubject ${i}\x1e`).join('\n')
  on('process.run', async (_$, e) => {
    const argv = ((e as { argv?: string[] }).argv ?? []).slice(3)
    const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never
    const no = { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
    if (argv[0] === 'rev-parse' && argv[1] === '--show-toplevel') return ok('/p\n')
    if (argv[0] === 'rev-parse' && argv[1] === 'HEAD') return ok(`${hash(1)}\n`)
    // The message read for the card holds the log's own separators, a tab and a carriage return.
    if (argv[0] === 'log' && argv[1] === '-1') return ok('A subject\n\n\tindented\r\nwith \x1b[31mcolour\x1b[0m\n')
    if (argv[0] === 'log') return ok(LOG)
    if (argv[0] === 'symbolic-ref') return ok('main\n')
    return no
  })
  await $.command.run({ command: 'graph' } as never)
  const ui = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'Pane', requestId: 'git-graph', props: paneProps(BODY_ROWS) })
  await ui.press({ key: `sel:${hash(1)}` })
  const open = JSON.stringify(await ui.drawn())
  expect(open.length).toBeLessThan(95000)
  expect(open).toContain('indented')
  expect(open).toContain('with [31mcolour[0m')
  // The selected row is at the top: a tick moves into its card, not past it.
  await $.ui.scroll(wheel(1))
  const into = JSON.stringify(await ui.drawn())
  expect(into).toContain('"marginTop":-1')
  expect(into).toContain('Subject 0')
  // Many ticks go through the card and on to the rows under it.
  for (let i = 0; i < 60; i++) await $.ui.scroll(wheel(1))
  const past = JSON.stringify(await ui.drawn())
  expect(past).not.toContain('Subject 0"')
  expect(past).not.toContain('marginTop')
  // And back up into the bottom of the card first.
  for (let i = 0; i < 60 && !JSON.stringify(await ui.drawn()).includes('Subject 0"'); i++) await $.ui.scroll(wheel(-1))
  expect(JSON.stringify(await ui.drawn())).toContain('"marginTop":-')
  await ui.unmount()
})
