import { expect, test } from 'claude-code/testing'

const PANE_PROPS = { title: 'Git graph', isFocused: false, bodyColumns: 120, placement: 'dock' } as never
const hash = (i: number) => i.toString(16).padStart(40, '0')

// The engine draws nothing of a panel over 100,000 characters and says "nothing to show yet".
test('a long history is drawn a page at a time, each page within what a panel may hold', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  on('ui.scroll', async () => ({ value: {} }) as never)
  // 150 commits and one more: every third a merge, so several lines run side by side.
  const LOG = Array.from({ length: 151 }, (_, i) => `${hash(i + 1)}\x1f${hash(i + 2)}${i % 3 === 0 ? ` ${hash(i + 5)}` : ''}\x1fA long author name\x1f${1700000000 - i}\x1fA commit subject of the usual length, about this long ${i}\x1e`).join('\n')
  on('process.run', async (_$, e) => {
    const argv = ((e as { argv?: string[] }).argv ?? []).slice(3)
    const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never
    const no = { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
    if (argv[0] === 'rev-parse' && argv[1] === '--show-toplevel') return ok('/p\n')
    if (argv[0] === 'rev-parse' && argv[1] === 'HEAD') return ok(`${hash(1)}\n`)
    if (argv[0] === 'log' && argv[1] === '-1') return ok('A subject\n\n\tindented\r\nwith \x1b[31mcolour\x1b[0m\n')
    if (argv[0] === 'log') return ok(LOG)
    if (argv[0] === 'symbolic-ref') return ok('main\n')
    return no
  })
  await $.command.run({ command: 'graph' } as never)
  const ui = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'Pane', requestId: 'git-graph', props: PANE_PROPS })
  const subject = (i: number) => `about this long ${i}"`
  const first = JSON.stringify(await ui.drawn())
  expect(first.length).toBeLessThan(95000)
  expect(first).toContain(subject(0))
  expect(first).not.toContain(subject(149))
  expect(first).not.toContain('newer commits')
  expect(first).toContain('of 150+')

  // Older, page by page, reaches every commit read; each page is within bounds.
  const seen = new Set<number>()
  const note = (text: string) => {
    for (let i = 0; i < 150; i++) if (text.includes(subject(i))) seen.add(i)
  }
  note(first)
  let pages = 1
  while (seen.size < 150 && pages < 20) {
    await ui.press({ key: 'more' })
    const page = JSON.stringify(await ui.drawn())
    expect(page.length).toBeLessThan(95000)
    expect(page).toContain('newer commits')
    note(page)
    pages += 1
  }
  expect(seen.size).toBe(150)
  expect(pages).toBeGreaterThan(1)

  // Newer goes back to where it started.
  for (let i = 0; i < pages; i++) {
    if (!JSON.stringify(await ui.drawn()).includes('newer commits')) break
    await ui.press({ key: 'newer' })
  }
  const back = JSON.stringify(await ui.drawn())
  expect(back).toContain(subject(0))
  expect(back).not.toContain('newer commits')

  // An unfolded row is counted too, and what git says is drawn without its control characters:
  // the message read here holds the log's own separators, a tab and a carriage return.
  await ui.press({ key: `sel:${hash(1)}` })
  const open = JSON.stringify(await ui.drawn())
  expect(open.length).toBeLessThan(95000)
  expect(open).toContain('indented')
  expect(open).toContain('with [31mcolour[0m')
  await ui.unmount()
})
