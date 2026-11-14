import { expect, test } from 'claude-code/testing'

import {
  UNCOMMITTED, actionsFor, cellSvg, cellText, commandLine, fmtAgo, isRefName, lanesOf, layout, matches, parseLog, parseRefs, parseStatus, targetName,
  touchesGit, fitColumns, parseNumstat, parseStashes, parseWorktrees, rowsOf, scrollList, withStashes,
} from '../hooks/core'

const c = (hash: string, parents: string[], subject = hash) => ({ hash, parents, author: 'Ann', at: 100, subject })

test('git output is read into commits, refs and changes', async () => {
  const log = `${'a'.repeat(40)}\x1f${'b'.repeat(40)} ${'c'.repeat(40)}\x1fAnn Lee\x1f1700000000\x1fMerge: a | b\x1e\n${'b'.repeat(40)}\x1f\x1fBo\x1f1690000000\x1ffirst\x1e\n`
  const commits = parseLog(log)
  expect(commits.length).toBe(2)
  expect(commits[0]).toEqual({ hash: 'a'.repeat(40), parents: ['b'.repeat(40), 'c'.repeat(40)], author: 'Ann Lee', at: 1700000000, subject: 'Merge: a | b' })
  expect(commits[1]?.parents).toEqual([])

  const refs = parseRefs(
    [`h1\x1frefs/heads/main\x1f`, `h2\x1frefs/remotes/origin/main\x1f`, `h3\x1frefs/remotes/origin/HEAD\x1f`, `tagobj\x1frefs/tags/v1\x1fh4`, `h5\x1frefs/tags/light\x1f`, `h6\x1frefs/stash\x1f`].join('\n'),
  )
  // An annotated tag names the commit behind it; origin/HEAD and the stash are not branches.
  expect(refs).toEqual([
    { kind: 'head', name: 'main', hash: 'h1' },
    { kind: 'remote', name: 'origin/main', hash: 'h2' },
    { kind: 'tag', name: 'v1', hash: 'h4' },
    { kind: 'tag', name: 'light', hash: 'h5' },
  ])
  expect(parseStatus(' M src/a.ts\n?? new file.txt\nD  gone.md\n')).toEqual([
    { code: 'M', path: 'src/a.ts' },
    { code: '??', path: 'new file.txt' },
    { code: 'D', path: 'gone.md' },
  ])
})

test('commits are laid out in lanes: a branch opens one, a merge joins two, a line keeps its lane', async () => {
  // m merges f into the main line; f and b both come from a.
  const rows = layout([c('m', ['b', 'f']), c('f', ['a']), c('b', ['a']), c('a', [])])
  expect(rows.map(r => r.lane)).toEqual([0, 1, 0, 0])
  // The merge sends a line down each lane; the feature's line then joins the main one at a.
  expect(rows[0]?.outLanes).toEqual([0, 1])
  expect(rows[1]?.outLanes).toEqual([1])
  expect(rows[3]?.ins).toEqual([0, 1])
  expect(rows[0]?.color).not.toBe(rows[1]?.color)
  expect(rows[2]?.color).toBe(rows[0]?.color)
  expect(lanesOf(rows)).toBe(2)
  // Two tips that never meet take a lane each; a freed lane is used again.
  const apart = layout([c('x', ['x0']), c('y', ['y0']), c('x0', []), c('y0', []), c('z', [])])
  expect(apart.map(r => r.lane)).toEqual([0, 1, 0, 1, 0])

  const svg = cellSvg(rows[0] as never, 2)
  expect(svg).toContain("height='24'")
  expect(svg.match(/<path /g)?.length).toBe(2)
  expect(svg).toContain('<circle')
  // The row between passes the feature's line straight through beside its own.
  expect(cellSvg(rows[2] as never, 2).match(/<path /g)?.length).toBe(3)
  // The checked-out commit is a ring, and the working tree's row is grey and dashed.
  expect(cellSvg(rows[0] as never, 2, { isHead: true })).toContain("fill='#1a1b26'")
  const dirty = layout([c(UNCOMMITTED, ['m']), c('m', [])])
  expect(cellSvg(dirty[0] as never, 1)).toContain('stroke-dasharray')
  expect(cellText(rows[2] as never, 2)).toBe('● │ ')
})

test('each action is the git command it shows, and names that git would misread are refused', async () => {
  const ctx = { branch: 'main', remotes: ['origin'] }
  const on = (t: never, id: string, input = '') => commandLine(actionsFor(t, ctx).find(a => a.id === id)?.commands(input) ?? [])
  const commit = { kind: 'commit', hash: 'abc1234def' } as never
  expect(on(commit, 'checkout')).toBe('git checkout abc1234def')
  expect(on(commit, 'branch-checkout', 'fix/x')).toBe('git checkout -b fix/x abc1234def')
  expect(on(commit, 'tag', 'v2')).toBe('git tag v2 abc1234def')
  expect(on(commit, 'reset-hard')).toBe('git reset --hard abc1234def')
  expect(actionsFor(commit, ctx).find(a => a.id === 'reset-hard')?.isDanger).toBe(true)
  expect(actionsFor(commit, ctx).find(a => a.id === 'merge')?.label).toBe('Merge into main')
  // A commit's actions sit under three headings in its panel.
  expect([...new Set(actionsFor(commit, ctx).map(a => a.group))]).toEqual(['commit', 'current', 'reset'])
  const other = { kind: 'head', name: 'dev' } as never
  expect(on(other, 'delete')).toBe('git branch -d dev')
  expect(on(other, 'rename', 'next')).toBe('git branch -m dev next')
  expect(on(other, 'push')).toBe('git push -u origin dev')
  // The checked-out branch cannot be checked out, merged into itself or deleted.
  expect(actionsFor({ kind: 'head', name: 'main' }, ctx).map(a => a.id)).toEqual(['rename', 'push'])
  expect(on({ kind: 'remote', name: 'origin/feat/a' } as never, 'delete')).toBe('git push origin --delete feat/a')
  expect(on({ kind: 'tag', name: 'v1' } as never, 'delete')).toBe('git tag -d v1')
  expect(on({ kind: 'changes' } as never, 'stash')).toBe('git stash push --include-untracked')
  expect(on({ kind: 'repo' } as never, 'fetch')).toBe('git fetch --all --prune')
  expect(targetName({ kind: 'head', name: 'dev' })).toBe('branch dev')

  for (const good of ['main', 'fix/x', 'v1.2.3', 'a_b-c']) expect(isRefName(good)).toBe(true)
  for (const bad of ['', '-x', '--force', 'a b', 'a..b', 'x.lock', 'a/', 'a;rm', '$(x)', 'a@{1}']) expect(isRefName(bad)).toBe(false)
})

test('times are short, the find box matches subject, author and hash, and a git command is noticed', async () => {
  expect([5, 300, 7200, 172800, 86400 * 90, 86400 * 800].map(fmtAgo)).toEqual(['5s', '5 min', '2 h', '2 d', '3 mo', '2 y'])
  const one = { hash: 'abc1234', parents: [], author: 'Ann Lee', at: 0, subject: 'Fix the Parser' }
  for (const q of ['parser', 'ann', 'abc', '']) expect(matches(one, q)).toBe(true)
  expect(matches(one, 'zzz')).toBe(false)
  for (const yes of ['git commit -m x', 'cd repo && git push', '(git status)']) expect(touchesGit(yes)).toBe(true)
  for (const no of ['legit command', 'cat .gitignore', 'npm test']) expect(touchesGit(no)).toBe(false)
})

test('the columns follow the panel: the author goes first, then the hash, then the age', async () => {
  expect(fitColumns('normal', 160, 4)).toEqual({ author: 18, age: 8, commit: 9 })
  expect(fitColumns('wide', 160, 4)).toEqual({ author: 28, age: 9, commit: 10 })
  // Not room for the preset's author column: it takes its compact width, then goes.
  expect(fitColumns('normal', 70, 4)).toEqual({ author: 12, age: 8, commit: 9 })
  expect(fitColumns('normal', 60, 4)).toEqual({ author: 0, age: 8, commit: 9 })
  expect(fitColumns('normal', 50, 4)).toEqual({ author: 0, age: 8, commit: 0 })
  expect(fitColumns('normal', 40, 4)).toEqual({ author: 0, age: 0, commit: 0 })
  // A wide graph takes room from the columns, never from the description.
  expect(fitColumns('normal', 70, 20)).toEqual({ author: 0, age: 8, commit: 0 })
})

test('line counts and stashes are read from git, and a stash sits just above the commit it was made on', async () => {
  expect(parseNumstat('12\t3\tsrc/a.ts\n-\t-\timg/logo.png\n0\t7\told name.txt\n')).toEqual([
    { added: 12, removed: 3, path: 'src/a.ts' },
    { added: null, removed: null, path: 'img/logo.png' },
    { added: 0, removed: 7, path: 'old name.txt' },
  ])
  const H = (ch: string) => ch.repeat(40)
  const stashes = parseStashes(`${H('d')}\x1f${H('b')} ${H('e')} ${H('f')}\x1fstash@{0}\x1f1700\x1fWIP on dev: x\x1e\n`)
  // Only the commit it was made on is kept as its parent: the others are the stash's own bookkeeping.
  expect(stashes).toEqual([{ hash: H('d'), parents: [H('b')], author: '', at: 1700, subject: 'stash@{0}: WIP on dev: x', stash: 'stash@{0}' }])
  const list = withStashes([c(H('a'), [H('b')]), c(H('b'), [])], stashes)
  expect(list.map(x => x.hash)).toEqual([H('a'), H('d'), H('b')])
  // It takes a lane of its own beside the line it hangs off, drawn as a square.
  const rows = layout(list)
  expect(rows.map(r => r.lane)).toEqual([0, 1, 0])
  expect(cellSvg(rows[1] as never, 2)).toContain('<rect')
  // A stash made on a commit that is not listed is left out.
  expect(withStashes([c(H('a'), [])], stashes).length).toBe(1)
  const on = actionsFor({ kind: 'stash', name: 'stash@{0}' }, { branch: 'main', remotes: [] })
  expect(on.map(a => commandLine(a.commands('fix')))).toEqual(['git stash apply stash@{0}', 'git stash pop stash@{0}', 'git stash branch fix stash@{0}', 'git stash drop stash@{0}'])
})

test('worktrees are read with the commit and branch each has checked out; a bare one is left out', () => {
  const H = (ch: string) => ch.repeat(40)
  const trees = parseWorktrees(`worktree /repo\nHEAD ${H('a')}\nbranch refs/heads/main\n\nworktree /repo/.claude/worktrees/brave-otter\nHEAD ${H('b')}\ndetached\nlocked by a session\n\nworktree /gone/old\nHEAD ${H('c')}\nbranch refs/heads/old\nprunable gitdir file points to non-existent location\n\nworktree /srv/bare.git\nbare\n`)
  expect(trees).toEqual([
    { path: '/repo', name: 'repo', head: H('a'), branch: 'main', isLocked: false, isPrunable: false },
    { path: '/repo/.claude/worktrees/brave-otter', name: 'brave-otter', head: H('b'), branch: null, isLocked: true, isPrunable: false },
    { path: '/gone/old', name: 'old', head: H('c'), branch: 'old', isLocked: false, isPrunable: true },
  ])
  expect(parseWorktrees('')).toEqual([])
})

test('the list scrolls a row at a time, and through a tall row a line at a time', async () => {
  // Row 2 is five lines tall; the furthest row at the top is 6.
  const h = (i: number) => (i === 2 ? 5 : 1)
  expect(scrollList({ from: 0, into: 0 }, 1, h, 6)).toEqual({ from: 1, into: 0 })
  expect(scrollList({ from: 0, into: 0 }, 4, h, 6)).toEqual({ from: 2, into: 2 })
  expect(scrollList({ from: 2, into: 4 }, 1, h, 6)).toEqual({ from: 3, into: 0 })
  // Up onto the tall row lands on its last line, and on up through it.
  expect(scrollList({ from: 3, into: 0 }, -1, h, 6)).toEqual({ from: 2, into: 4 })
  expect(scrollList({ from: 3, into: 0 }, -6, h, 6)).toEqual({ from: 1, into: 0 })
  // It stops at both ends.
  expect(scrollList({ from: 0, into: 0 }, -3, h, 6)).toEqual({ from: 0, into: 0 })
  expect(scrollList({ from: 5, into: 0 }, 9, h, 6)).toEqual({ from: 6, into: 0 })
})

test('a drawn piece is counted in lines as the terminal lays it out', async () => {
  const T = (text: string, wrap?: string) => ({ type: 'Text', props: wrap ? { wrap } : {}, children: [text] })
  const B = (props: Record<string, unknown>, ...children: unknown[]) => ({ type: 'Box', props, children })
  expect(rowsOf(T('one\ntwo'), 80)).toBe(2)
  expect(rowsOf(T('x'.repeat(100), 'wrap'), 40)).toBe(3)
  expect(rowsOf(B({}, T('a'), T('b')), 80)).toBe(1)
  expect(rowsOf(B({ flexDirection: 'column', rowGap: 1 }, T('a'), null, [T('b'), T('c')]), 80)).toBe(5)
  // A card: a margin of a line, a border, a line of padding each way.
  expect(rowsOf(B({ paddingY: 1 }, B({ flexDirection: 'column', borderStyle: 'round', paddingY: 1 }, T('title'))), 80)).toBe(7)
  expect(rowsOf(B({ position: 'absolute' }, T('over')), 80)).toBe(0)
  expect(rowsOf({ type: 'Button', props: { key: 'k', label: 'go' } }, 80)).toBe(1)
})
