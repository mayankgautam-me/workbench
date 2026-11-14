import { expect, mock, test } from 'claude-code/testing'

const PANE_PROPS = { title: 'Git graph', isFocused: false, bodyColumns: 120, placement: 'dock' } as never
const H = (ch: string) => ch.repeat(40)
const LOG = [
  `${H('a')}\x1f${H('b')}\x1fAnn\x1f1700000300\x1fAdd the graph\x1e`,
  `${H('b')}\x1f${H('c')}\x1fAnn\x1f1700000200\x1fFix the parser\x1e`,
  `${H('c')}\x1f\x1fBo\x1f1700000100\x1fFirst commit\x1e`,
].join('\n')
const REFS = [`${H('a')}\x1frefs/heads/main\x1f`, `${H('b')}\x1frefs/heads/dev\x1f`, `${H('b')}\x1frefs/remotes/origin/main\x1f`, `${H('c')}\x1frefs/tags/v1\x1f`].join('\n')

test('the panel draws the repository as a graph, and an action runs only after a yes', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('store.set', async () => ({ value: undefined }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  const clock = mock.clock(on)
  let isRepo = true
  let status = ' M src/a.ts\n?? notes.md\n'
  const ran: string[] = []
  let operation = false
  let refuse = ''
  let refusal = ''
  on('process.run', async (_$, e) => {
    const argv = ((e as { argv?: string[] }).argv ?? []).slice(3)
    const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never
    if (!isRepo) return { value: { exitCode: 128, stdout: '', stderr: 'not a git repository', isStdoutTruncated: false, isStderrTruncated: false } } as never
    const no = { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
    if (argv[0] === 'rev-parse' && argv[1] === '--show-toplevel') return ok('/p\n')
    if (argv[0] === 'rev-parse' && argv[1] === '--abbrev-ref') return ok('origin/main\n')
    if (argv[0] === 'rev-parse' && argv[1] === '-q') return operation && argv[3] === 'MERGE_HEAD' ? ok(`${H('f')}\n`) : no
    if (argv[0] === 'for-each-ref' && String(argv[1]).includes('symref')) return ok('origin/main\n')
    if (refuse && argv[0] === refuse) return { value: { exitCode: 1, stdout: '', stderr: refusal, isStdoutTruncated: false, isStderrTruncated: false } } as never
    if (argv[0] === 'rev-parse') return ok(`${H('a')}\n`)
    if (argv[0] === 'log' && argv[1] === '-1') return ok('Fix the parser\n\nIt dropped the last record\nwhen the log ended without a newline.\n')
    if (argv[0] === 'log') return ok(LOG)
    if (argv[0] === 'stash' && argv[1] === 'list') return ok(`${H('d')}\x1f${H('b')} ${H('e')}\x1fstash@{0}\x1f1700000250\x1fWIP on dev: try a cache\x1e\n`)
    if (argv[0] === 'diff-tree') return ok('12\t3\tsrc/parser.ts\n-\t-\tlogo.png\n')
    if (argv[0] === 'diff') return ok(`${argv.includes(H('c')) ? '40\t0\tsrc/graph.ts' : '5\t1\tsrc/cache.ts'}\n`)
    if (argv[0] === 'for-each-ref') return ok(REFS)
    if (argv[0] === 'symbolic-ref') return ok('main\n')
    if (argv[0] === 'status') return ok(status)
    if (argv[0] === 'remote') return ok('origin\n')
    if (argv[0] === 'rev-list') return ok('3\t5\n')
    if (argv[0] === 'worktree') return ok(`worktree /p\nHEAD ${H('a')}\nbranch refs/heads/main\n\nworktree /p/.claude/worktrees/brave-otter\nHEAD ${H('b')}\nbranch refs/heads/dev\n\nworktree /p/.claude/worktrees/calm-heron\nHEAD ${H('c')}\ndetached\nlocked\n`)
    ran.push(argv.join(' '))
    if (argv[0] === 'stash') status = ''
    return ok('')
  })

  expect(JSON.stringify(await $.command.run({ command: 'graph' } as never))).toContain('Git graph shown.')
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'git-graph', surface, component: 'Pane', requestId: 'git-graph', props: PANE_PROPS })
    const drawn = JSON.stringify(await ui.drawn())
    for (const piece of ['Uncommitted changes (2)', 'Add the graph', 'Fix the parser', 'First commit', 'main', 'dev', 'origin/main', '◇ v1', 'aaaaaaa', 'stash@{0}: WIP on dev: try a cache', 'All branches', 'BRANCHES', 'SHOW', 'REMOTE', 'COLUMNS', 'FIND', '● ', 'remotes', 'Fetch', 'Normal'])
      expect(drawn).toContain(piece)
    // Each row's graph cell sits in a column of a set width: without one the drawing is not shown.
    if (surface === 'desktop') expect(drawn).toContain('{\"width\":6,\"flexShrink\":0},\"children\":[{\"type\":\"Svg\"')
    for (const heading of ['DESCRIPTION', 'AUTHOR', 'COMMIT']) expect(drawn).toContain(heading)
    if (surface === 'desktop') expect(drawn).toContain('<svg xmlns')
    else expect(drawn).not.toContain('<svg xmlns')
    await ui.unmount()
  }

  // A narrow panel drops the author and the hash and keeps the description and the age.
  const narrow = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'Pane', requestId: 'git-graph', props: { ...(PANE_PROPS as object), bodyColumns: 50 } as never })
  const slim = JSON.stringify(await narrow.drawn())
  for (const kept of ['DESCRIPTION', 'AGE', 'Add the graph']) expect(slim).toContain(kept)
  for (const gone of ['AUTHOR', '"COMMIT"', '"Ann"']) expect(slim).not.toContain(gone)
  await narrow.unmount()

  // The other worktrees are named on the commits they have checked out, not the one the session
  // is in; a commit's card says where each is; the toggle beside remotes and tags hides them.
  const trees = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'Pane', requestId: 'git-graph', props: PANE_PROPS })
  const withTrees = JSON.stringify(await trees.drawn())
  for (const piece of ['⌂ brave-otter', '⌂ calm-heron', '"worktrees"']) expect(withTrees).toContain(piece)
  // Push and Pull say how many commits the branch is ahead of its upstream and behind it.
  for (const piece of ['Push ↑5', 'Pull ↓3']) expect(withTrees).toContain(piece)
  expect(withTrees).not.toContain('⌂ p"')
  await trees.press({ key: `sel:${H('c')}` })
  expect(JSON.stringify(await trees.drawn())).toContain('worktree on a detached HEAD, locked  ·  /p/.claude/worktrees/calm-heron')
  await trees.press({ key: `sel:${H('c')}` })
  await trees.press({ key: 'worktrees' })
  expect(JSON.stringify(await trees.drawn())).not.toContain('⌂ brave-otter')
  await trees.press({ key: 'worktrees' })
  expect(JSON.stringify(await trees.drawn())).toContain('⌂ brave-otter')
  await trees.unmount()

  // Select the uncommitted changes, pick Stash: nothing runs until Run is pressed.
  const ui = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'Pane', requestId: 'git-graph', props: PANE_PROPS })
  await ui.press({ key: 'sel:*' })
  expect(JSON.stringify(await ui.drawn())).toContain('notes.md')
  // The selected row's panel is a bordered card with a caption beside its buttons.
  expect(JSON.stringify(await ui.drawn())).toContain('\"borderStyle\":\"round\"')
  expect(JSON.stringify(await ui.drawn())).toContain('WORKING TREE')
  await ui.press({ key: 'act:changes:stash' })
  expect(JSON.stringify(await ui.drawn())).toContain('Run git stash push --include-untracked on the working tree?')
  expect(ran).toEqual([])
  await ui.press({ key: 'ask-run' })
  expect(ran).toEqual(['stash push --include-untracked'])
  const after = JSON.stringify(await ui.drawn())
  expect(after).not.toContain('Uncommitted changes')
  // What happened is said in a toast at the foot of the panel: a bordered box with a mark, a title and the command.
  // Read from the panel as it is mounted now.
  let current = ui
  const band = async () => ({ b: current, text: JSON.stringify(await current.drawn()) })
  // And above the prompt there is no toast.
  const above = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120 } as never })
  expect(JSON.stringify(await above.drawn())).not.toContain('Stash: done')
  await above.unmount()
  let shown = await band()
  for (const piece of ['Stash: done', 'git stash push --include-untracked', '✓', '"borderStyle":"round"', 'dismiss', '"paddingX":2,"paddingY":1']) expect(shown.text).toContain(piece)
  // It leaves by itself after a few seconds.
  await clock.advance(6000)
  expect((await band()).text).not.toContain('Stash: done')

  // A dangerous action says so, and Cancel drops it.
  await ui.press({ key: `sel:${H('b')}` })
  await ui.press({ key: `act:c:${H('b')}:reset-hard` })
  expect(JSON.stringify(await ui.drawn())).toContain('This cannot be undone from here.')
  await ui.press({ key: 'ask-cancel' })
  expect(ran.length).toBe(1)
  const card = JSON.stringify(await ui.drawn())
  // The card carries the rest of the message and the files the commit changed, with line counts.
  for (const piece of ['It dropped the last record', '2 FILES CHANGED', '+12', '−3', 'src/parser.ts', 'bin', 'logo.png', 'Mark to compare']) expect(card).toContain(piece)
  for (const piece of ['Fix the parser', 'COMMIT', 'RESET MAIN', 'Revert', 'Soft', 'Hard']) expect(card).toContain(piece)
  // The commit is behind HEAD already: picking or merging it would do nothing, so neither is offered.
  for (const gone of ['Cherry pick', 'Merge into main']) expect(card).not.toContain(gone)
  // One gap everywhere: two cells across and one row down, also where a row of buttons wraps; no odd one-off paddings.
  for (const piece of ['"columnGap":2,"rowGap":1', '"columnGap":4,"rowGap":1', '"paddingX":2,"paddingY":1,"rowGap":1', '"paddingLeft":2']) expect(card).toContain(piece)
  expect(card).not.toMatch(/"padding(Left|Right|Top|Bottom)":(1|3)[,}]/)
  // The column preset cycles, and the columns take its widths.
  await ui.press({ key: 'columns' })
  expect(JSON.stringify(await ui.drawn())).toContain('Wide')
  expect(JSON.stringify(await ui.drawn())).toContain('{\"width\":28,')
  // A branch on that commit has its own actions.
  await ui.press({ key: 'act:head:dev:checkout' })
  await ui.press({ key: 'ask-run' })
  expect(ran[1]).toBe('checkout dev')
  // Mark the first commit, select another: the card lists what differs between the two.
  await ui.press({ key: `sel:${H('c')}` })
  await ui.press({ key: 'compare-mark' })
  await ui.press({ key: `sel:${H('a')}` })
  const diff = JSON.stringify(await ui.drawn())
  for (const piece of ['DIFFERS FROM CCCCCCC IN 1 FILE', '+40', 'src/graph.ts', '⇄ First commit']) expect(diff).toContain(piece)
  await ui.press({ key: 'compare-clear' })
  expect(JSON.stringify(await ui.drawn())).toContain('2 FILES CHANGED')
  // A stash hangs off the commit it was made on, shows what it holds, and has its own actions.
  await ui.press({ key: `sel:${H('d')}` })
  const stash = JSON.stringify(await ui.drawn())
  for (const piece of ['src/cache.ts', 'Apply', 'Pop', 'Drop']) expect(stash).toContain(piece)
  await ui.press({ key: 'act:stash:stash@{0}:pop' })
  expect(JSON.stringify(await ui.drawn())).toContain('Run git stash pop stash@{0} on stash stash@{0}?')
  await ui.press({ key: 'ask-cancel' })
  await ui.unmount()

  // Git refusing before it changes anything is a warning that says why, without git's hints; it stays longer.
  const again = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'Pane', requestId: 'git-graph', props: PANE_PROPS })
  current = again
  refuse = 'checkout'
  refusal = 'error: Your local changes to the following files would be overwritten by checkout:\n\tsrc/a.ts\nPlease commit your changes or stash them before you switch branches.\nhint: stash them\nAborting\n'
  await again.press({ key: `sel:${H('c')}` })
  await again.press({ key: `act:c:${H('c')}:checkout` })
  await again.press({ key: 'ask-run' })
  shown = await band()
  for (const piece of ['Checkout: git refused, nothing was changed', 'would be overwritten by checkout: src/a.ts Please commit', '!']) expect(shown.text).toContain(piece)
  for (const gone of ['hint', 'Aborting', 'error:']) expect(shown.text).not.toContain(gone)
  await clock.advance(6000)
  expect((await band()).text).toContain('git refused')
  // Any other failure is an error, and stays until it is dismissed.
  refusal = 'fatal: unable to access the repository\n'
  await again.press({ key: `act:c:${H('c')}:checkout` })
  await again.press({ key: 'ask-run' })
  await clock.advance(60000)
  shown = await band()
  for (const piece of ['Checkout failed', 'unable to access the repository (git checkout', '✕']) expect(shown.text).toContain(piece)
  await shown.b.press({ key: 'toast-dismiss' })
  expect(JSON.stringify(await shown.b.drawn())).not.toContain('Checkout failed')
  // A merge that stopped on a conflict: a bar on top to continue or abort it, and nothing offered that git would refuse meanwhile.
  refuse = ''
  operation = true
  await again.press({ key: 'refresh' })
  const during = JSON.stringify(await again.drawn())
  for (const piece of ['A merge is in progress', 'Continue the merge', 'Abort the merge', 'Branch…', 'Tag…']) expect(during).toContain(piece)
  for (const gone of ['Cherry pick', 'Soft', 'Checkout']) expect(during).not.toContain(gone)
  await again.press({ key: 'act:operation:abort' })
  await again.press({ key: 'ask-run' })
  expect(ran.at(-1)).toBe('merge --abort')
  operation = false
  await again.unmount()

  // Outside a repository there is no panel, and /graph says so.
  isRepo = false
  await $.prompt.submit({ text: 'hello' } as never).catch(() => undefined)
  expect(JSON.stringify(await $.command.run({ command: 'graph' } as never))).toContain('not in a git repository')
})
