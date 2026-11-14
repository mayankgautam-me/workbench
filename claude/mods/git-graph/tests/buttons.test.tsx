import { expect, mock, test } from 'claude-code/testing'

// Every button the panel draws is pressed here, through the panel itself: select each row, press
// each action on it, give a name where one is asked for, press Run, and see that the command
// reached git and that a toast said it was done. Whether git accepts each command is checked
// against real git by scripts/all-buttons.mts; the kit has no git.
const PANE_PROPS = { title: 'Git graph', isFocused: false, bodyColumns: 120, placement: 'dock' } as never
const H = (ch: string) => ch.repeat(40)
// main at a (a merge of b and e), dev ahead on f, origin/feat on e, a tag on c, a stash on b.
const LOG = [
  `${H('f')}\x1f${H('b')}\x1fAnn\x1f1700000350\x1fDev work\x1e`,
  `${H('a')}\x1f${H('b')} ${H('e')}\x1fAnn\x1f1700000300\x1fMerge feat\x1e`,
  `${H('e')}\x1f${H('c')}\x1fBo\x1f1700000250\x1fFeat work\x1e`,
  `${H('b')}\x1f${H('c')}\x1fAnn\x1f1700000200\x1fFix the parser\x1e`,
  `${H('c')}\x1f\x1fBo\x1f1700000100\x1fFirst commit\x1e`,
].join('\n')
const REFS = [`${H('a')}\x1frefs/heads/main\x1f`, `${H('f')}\x1frefs/heads/dev\x1f`, `${H('a')}\x1frefs/remotes/origin/main\x1f`, `${H('e')}\x1frefs/remotes/origin/feat\x1f`, `${H('c')}\x1frefs/tags/v1\x1f`].join('\n')

test('every button the panel draws runs its command and says so', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('store.set', async () => ({ value: undefined }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  mock.clock(on)
  const ran: string[] = []
  on('process.run', async (_$, e) => {
    const argv = ((e as { argv?: string[] }).argv ?? []).slice(3)
    const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never
    if (argv[0] === 'rev-parse' && argv[1] === '--show-toplevel') return ok('/p\n')
    if (argv[0] === 'rev-parse' && argv[1] === '--abbrev-ref') return ok('origin/main\n')
    if (argv[0] === 'rev-parse' && argv[1] === '-q') return { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } } as never
    if (argv[0] === 'rev-parse') return ok(`${H('a')}\n`)
    if (argv[0] === 'log' && argv[1] === '-1') return ok('Subject\n')
    if (argv[0] === 'log') return ok(LOG)
    if (argv[0] === 'stash' && argv[1] === 'list') return ok(`${H('d')}\x1f${H('b')} ${H('9')}\x1fstash@{0}\x1f1700000260\x1fWIP on main: try a cache\x1e\n`)
    if (argv[0] === 'diff-tree' || argv[0] === 'diff') return ok('1\t1\tsrc/a.ts\n')
    if (argv[0] === 'for-each-ref') return ok(String(argv[1]).includes('symref') ? 'origin/main\n' : REFS)
    if (argv[0] === 'symbolic-ref') return ok('main\n')
    if (argv[0] === 'status') return ok(' M src/a.ts\n?? notes.md\n')
    if (argv[0] === 'remote') return ok('origin\n')
    if (argv[0] === 'rev-list') return ok('3\t5\n')
    if (argv[0] === 'worktree') return ok('')
    ran.push(argv.join(' '))
    return ok('')
  })

  await $.command.run({ command: 'graph' } as never)
  const ui = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'Pane', requestId: 'git-graph', props: PANE_PROPS })
  const keysOf = async (prefix: string) => [...new Set([...JSON.stringify(await ui.drawn()).matchAll(/"key":"([^"]+)"/g)].map(m => m[1] as string).filter(k => k.startsWith(prefix)))]
  const toastText = async () => JSON.stringify(await ui.drawn())
  const pressed: string[] = []
  const pressAll = async () => {
    for (const key of await keysOf('act:')) {
      if (pressed.includes(key)) continue
      pressed.push(key)
      const before = ran.length
      await ui.press({ key })
      // Nothing runs on the first press: a name is asked for, or a yes.
      expect(ran.length).toBe(before)
      if ((await keysOf('ask-name')).length) await ui.input({ key: 'ask-name', text: 'new-name' })
      const asked = JSON.stringify(await ui.drawn())
      expect(asked).toContain('Run git ')
      await ui.press({ key: 'ask-run' })
      if (ran.length !== before + 1) throw new Error(`${key}: pressed Run and no command reached git`)
      const said = await toastText()
      if (!said.includes(': done')) throw new Error(`${key}: ran, and no toast said so`)
      expect(said).toContain(`git ${ran.at(-1)}`)
    }
  }
  // The toolbar's buttons, then each row's.
  await pressAll()
  const rows = await keysOf('sel:')
  expect(rows.length).toBe(7)
  for (const row of rows) {
    await ui.press({ key: row })
    await pressAll()
  }
  // Every kind of target was reached, and each action on it.
  const ids = pressed.map(k => k.replace(/[0-9a-f]{40}/, h => h.slice(0, 1)))
  for (const key of ['act:repo:fetch', 'act:repo:pull', 'act:repo:push', 'act:changes:stash', 'act:changes:discard', 'act:changes:clean', 'act:c:f:cherry-pick', 'act:c:f:merge', 'act:c:f:rebase', 'act:c:b:revert', 'act:c:b:reset-hard', 'act:c:a:branch', 'act:c:a:tag', 'act:head:dev:delete-force', 'act:head:main:rename', 'act:remote:origin/feat:checkout', 'act:remote:origin/feat:delete', 'act:tag:v1:push', 'act:tag:v1:delete', 'act:stash:stash@{0}:pop', 'act:stash:stash@{0}:branch'])
    expect(ids).toContain(key)
  // What git would refuse is not drawn at all.
  for (const key of ['act:c:a:reset-hard', 'act:c:b:cherry-pick', 'act:c:b:merge', 'act:c:f:revert', 'act:head:dev:delete', 'act:head:main:checkout', 'act:remote:origin/main:checkout', 'act:remote:origin/main:delete', 'act:remote:origin/main:pull', 'act:remote:origin/feat:merge'])
    expect(ids).not.toContain(key)
  // A merge is picked or reverted against its first parent, and what would stop on local changes takes them along.
  for (const cmd of [`revert --no-edit -m 1 ${H('a')}`, `rebase --autostash ${H('f')}`, `merge --no-edit --autostash ${H('f')}`, 'pull --no-rebase --no-edit --autostash', 'branch new-name ' + H('a'), 'stash branch new-name stash@{0}'])
    expect(ran).toContain(cmd)
  expect(pressed.length).toBeGreaterThan(55)
  // The other buttons: the view's switches, the columns, compare, refresh.
  for (const key of ['remotes', 'tags', 'columns', 'refresh', 'compare-mark', 'compare-clear']) await ui.press({ key })
  await ui.unmount()
  // The toast of the last action is pinned to the bottom centre of what the panel shows: with 30
  // rows in view it takes the last 8 of them, and the list scrolls behind it. The panel is as tall
  // as its window, drawn a row down where the app has moved its window over the row below.
  const scrolled = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'Pane', requestId: 'git-graph', props: { ...(PANE_PROPS as object), scroll: { offset: 40, bodyRows: 30 } } as never })
  const pinned = JSON.stringify(await scrolled.drawn())
  for (const piece of ['"key":"toast-pin","position":"absolute","top":22', '"height":8', '"justifyContent":"flex-end","alignItems":"center"', '"height":30', '"marginTop":2', '"backgroundColor":"#24283b"', ': done']) expect(pinned).toContain(piece)
  expect(pinned).not.toContain('"key":"toast-row"')
  await scrolled.unmount()
})
