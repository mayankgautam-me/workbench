// Pure logic for the git graph: reading git's output, laying the commits out in lanes, drawing
// one row's piece of the graph, and the git commands behind each action. Nothing here touches `$`.

import type { Change, Commit, FileStat, Ref, Target, Worktree } from '../types'

/** The row that stands for the working tree's uncommitted changes. */
export const UNCOMMITTED = '*'

const US = '\x1f'
const RS = '\x1e'
/** One commit per record: hash, parents, author, time, subject. */
export const LOG_FORMAT = '%H%x1f%P%x1f%an%x1f%at%x1f%s%x1e'
/** One ref per line: the object it names, its full name, and for an annotated tag the commit behind it. */
export const REF_FORMAT = '%(objectname)%1f%(refname)%1f%(*objectname)'

/**
 * Text as the panel may draw it. The engine draws nothing of a panel that holds a control
 * character other than a newline, and git hands some on: a tab or a carriage return in a commit
 * message, the returns in a remote's progress lines, an escape sequence in a hook's output.
 */
export const plain = (text: string) => text.replace(/\t/g, '  ').replace(/[\u0000-\u0009\u000b-\u001f\u007f-\u009f]/g, '')

export const parseLog = (text: string): Commit[] =>
  text
    .split(RS)
    .map(r => r.replace(/^\s+/, ''))
    .filter(Boolean)
    .map(r => {
      const [hash = '', parents = '', author = '', at = '0', subject = ''] = r.split(US)
      return { hash, parents: parents.split(' ').filter(Boolean), author: plain(author), at: Number(at) || 0, subject: plain(subject) }
    })
    .filter(c => /^[0-9a-f]{7,64}$/.test(c.hash))

export const parseRefs = (text: string): Ref[] =>
  text
    .split('\n')
    .map(line => line.split(US))
    .filter(p => p.length >= 2 && p[0])
    .flatMap(([object = '', full = '', peeled = '']): Ref[] => {
      const hash = peeled || object
      if (full.startsWith('refs/heads/')) return [{ kind: 'head', name: full.slice(11), hash }]
      if (full.startsWith('refs/tags/')) return [{ kind: 'tag', name: full.slice(10), hash }]
      // `origin/HEAD` only says which remote branch is the default: not a branch to show.
      if (full.startsWith('refs/remotes/') && !full.endsWith('/HEAD')) return [{ kind: 'remote', name: full.slice(13), hash }]
      return []
    })

/** `git status --porcelain`: a two-letter code and a path per line. */
export const parseStatus = (text: string): Change[] =>
  text
    .split('\n')
    .filter(line => line.length > 3)
    .map(line => ({ code: line.slice(0, 2).trim() || '?', path: plain(line.slice(3)) }))

/** `git diff --numstat`: lines added, lines removed and a path per line; `-` for a binary file. */
export const parseNumstat = (text: string): FileStat[] =>
  text
    .split('\n')
    .map(line => line.split('\t'))
    .filter(p => p.length >= 3)
    .map(([a = '', r = '', ...path]) => ({ added: a === '-' ? null : Number(a) || 0, removed: r === '-' ? null : Number(r) || 0, path: plain(path.join('\t')) }))

/** `git worktree list --porcelain`: a block of lines per worktree, a blank line between. A bare one has no checkout to show. */
export const parseWorktrees = (text: string): Worktree[] =>
  text
    .split(/\n\s*\n/)
    .map(block => block.split('\n').filter(Boolean))
    .flatMap((lines): Worktree[] => {
      const value = (word: string) => lines.find(l => l.startsWith(`${word} `))?.slice(word.length + 1) ?? ''
      const has = (word: string) => lines.some(l => l === word || l.startsWith(`${word} `))
      const path = plain(value('worktree'))
      const head = value('HEAD')
      if (!path || !/^[0-9a-f]{7,64}$/.test(head) || has('bare')) return []
      const branch = value('branch')
      return [{ path, name: path.replace(/\/+$/, '').split('/').pop() || path, head, branch: branch.startsWith('refs/heads/') ? branch.slice(11) : null, isLocked: has('locked'), isPrunable: has('prunable') }]
    })

/** One stash per record of `git stash list`: its commit, the commit it was made on, its name, time and message. */
export const STASH_FORMAT = '%H%x1f%P%x1f%gd%x1f%at%x1f%gs%x1e'
export const parseStashes = (text: string): Commit[] =>
  text
    .split(RS)
    .map(r => r.replace(/^\s+/, ''))
    .filter(Boolean)
    .map(r => {
      const [hash = '', parents = '', name = '', at = '0', subject = ''] = r.split(US)
      // A stash is drawn hanging off the commit it was made on: its other parents are its own bookkeeping.
      return { hash, parents: parents.split(' ').filter(Boolean).slice(0, 1), author: '', at: Number(at) || 0, subject: plain(`${name}: ${subject}`), stash: name }
    })
    .filter(c => /^[0-9a-f]{7,64}$/.test(c.hash) && c.parents.length === 1)

/** The commits with each stash put just above the commit it was made on; a stash whose commit is not listed is left out. */
export const withStashes = (commits: readonly Commit[], stashes: readonly Commit[]): Commit[] =>
  commits.flatMap(c => [...stashes.filter(s => s.parents[0] === c.hash), c])

// ── Lanes ────────────────────────────────────────────────────────────────────────────────────

/** A line running down the graph: the commit it is heading for, and its colour. */
export type Lane = { hash: string; color: number }
export type Row = {
  commit: Commit
  /** The lane the commit's dot sits in, and its colour. */
  lane: number
  color: number
  /** The lanes as they stand above this row and below it. */
  before: (Lane | null)[]
  after: (Lane | null)[]
  /** Lanes above that end at this commit. */
  ins: number[]
  /** Lines from this commit down to its parents. */
  outs: Lane[]
  outLanes: number[]
}

/**
 * Gives every commit a lane, newest first. A lane is a line waiting for one commit; a commit
 * takes the lane waiting for it (or the first free one), hands it on to its first parent, and
 * opens a lane for each further parent. Lanes keep their place, so a line never jumps sideways
 * except where branches part or meet.
 */
export const layout = (commits: readonly Commit[]): Row[] => {
  const lanes: (Lane | null)[] = []
  let nextColor = 0
  const free = () => {
    const i = lanes.indexOf(null)
    if (i >= 0) return i
    lanes.push(null)
    return lanes.length - 1
  }
  return commits.map(commit => {
    const before = lanes.slice()
    const ins = lanes.flatMap((l, i) => (l?.hash === commit.hash ? [i] : []))
    const lane = ins[0] ?? free()
    const color = ins.length > 0 ? (lanes[lane] as Lane).color : nextColor++
    for (const i of ins) lanes[i] = null
    const outs: Lane[] = []
    const outLanes: number[] = []
    commit.parents.forEach((parent, k) => {
      const waiting = k === 0 ? -1 : lanes.findIndex(l => l?.hash === parent)
      if (waiting >= 0) {
        // A merged-in parent some line is already heading for: join that line.
        outs.push(lanes[waiting] as Lane)
        outLanes.push(waiting)
        return
      }
      // The first parent carries this commit's line straight on, in its lane, even where another
      // line is heading for the same commit: the two meet there. Other parents open a new lane.
      const at = k === 0 ? lane : free()
      const line = { hash: parent, color: k === 0 ? color : nextColor++ }
      lanes[at] = line
      outs.push(line)
      outLanes.push(at)
    })
    while (lanes.length > 0 && lanes[lanes.length - 1] === null) lanes.pop()
    return { commit, lane, color, before, after: lanes.slice(), ins, outs, outLanes }
  })
}

/** How many lanes the widest of these rows uses. */
export const lanesOf = (rows: readonly Row[]) =>
  Math.max(1, ...rows.map(r => Math.max(r.before.length, r.after.length, r.lane + 1)))

// Tokyo Night, one colour per branch line.
export const LANE_COLORS = ['#7aa2f7', '#bb9af7', '#9ece6a', '#e0af68', '#7dcfff', '#f7768e', '#73daca', '#ff9e64']
export const laneColor = (i: number) => LANE_COLORS[i % LANE_COLORS.length] as string
export const LANE_W = 14
export const ROW_H = 24
const INK = '#1a1b26'
const GREY = '#737aa2'
const n = (x: number) => (Math.round(x * 10) / 10).toString()

/** The width in pixels of a graph cell holding this many lanes. */
export const cellWidth = (lanes: number) => 12 + Math.max(1, lanes) * LANE_W

/**
 * One row's piece of the graph, as an SVG of exactly `ROW_H` pixels: the lines passing through,
 * the lines ending at this commit, the lines leaving for its parents, and its dot. Rows stacked
 * with no gap join into one graph.
 */
export const cellSvg = (row: Row, lanes: number, opt: { isHead?: boolean; isSelected?: boolean } = {}) => {
  const isStash = row.commit.stash !== undefined
  const W = cellWidth(lanes)
  const H = ROW_H
  const mid = H / 2
  const x = (i: number) => 10 + i * LANE_W
  const isUncommitted = row.commit.hash === UNCOMMITTED
  const ink = (c: number) => (isUncommitted ? GREY : laneColor(c))
  const dash = isUncommitted ? " stroke-dasharray='3 3'" : ''
  // What every line shares is said once, on the group round them, and attributes are quoted
  // singly: the panel may hold only so many characters, and a row's drawing is most of its own.
  const line = (d: string, color: string, extra = '') => `<path d='${d}' stroke='${color}'${extra}/>`
  // A line that changes lane bends through the half row it has.
  const bend = (x1: number, y1: number, x2: number, y2: number) =>
    x1 === x2 ? `M${n(x1)} ${n(y1)} L${n(x2)} ${n(y2)}` : `M${n(x1)} ${n(y1)} C${n(x1)} ${n((y1 + y2) / 2 + (y2 - y1) * 0.3)} ${n(x2)} ${n((y1 + y2) / 2 - (y2 - y1) * 0.3)} ${n(x2)} ${n(y2)}`
  let lines = ''
  row.before.forEach((l, i) => {
    if (!l) return
    if (row.ins.includes(i)) lines += line(bend(x(i), 0, x(row.lane), mid), laneColor(l.color))
    else lines += line(`M${n(x(i))} 0 L${n(x(i))} ${H}`, laneColor(l.color))
  })
  row.outs.forEach((l, k) => {
    lines += line(bend(x(row.lane), mid, x(row.outLanes[k] as number), H), ink(l.color), dash)
  })
  let out = lines ? `<g fill='none' stroke-width='2' stroke-linecap='round'>${lines}</g>` : ''
  const cx = x(row.lane)
  const color = ink(row.color)
  // The checked-out commit is a ring; the working tree a grey ring; every other commit a dot.
  out += isStash
    ? // A stash is a small hollow square: put aside, not part of any branch.
      `<rect x='${n(cx - 3.5)}' y='${n(mid - 3.5)}' width='7' height='7' rx='1.5' fill='${INK}' stroke='${color}' stroke-width='2'/>`
    : opt.isHead || isUncommitted
      ? `<circle cx='${n(cx)}' cy='${n(mid)}' r='4' fill='${INK}' stroke='${color}' stroke-width='2'/>`
      : `<circle cx='${n(cx)}' cy='${n(mid)}' r='4' fill='${color}'/>`
  if (opt.isSelected) out += `<circle cx='${n(cx)}' cy='${n(mid)}' r='7' fill='none' stroke='${color}' stroke-width='1.2' opacity='0.8'/>`
  return `<svg xmlns='http://www.w3.org/2000/svg' width='${W}' height='${H}' viewBox='0 0 ${W} ${H}'>${out}</svg>`
}

// ── What the panel can hold ──────────────────────────────────────────────────────────────────

/**
 * The engine draws nothing of a panel whose tree is over 100,000 characters once written out,
 * and shows its own "nothing to show yet" instead. The graph keeps well under: the list draws
 * only the rows from the top of its own window, as many as the rest of the panel leaves room
 * for, and scrolling draws the next ones.
 */
export const TREE_BUDGET = 85000
/** The least the rows get, however much the rest of the panel takes. */
export const ROWS_BUDGET_MIN = 20000

/** A drawn piece's size as the engine counts it, near enough: written out, each handler as a short name. */
export const sizeOf = (tree: unknown): number =>
  (JSON.stringify(tree, (_key, value) => (typeof value === 'function' ? 'handler:0000000000000000' : value)) ?? '').length

/** The end of the run of items that starts at `from`: as many of the items up to `end` as fit the budget, and always one. */
export const pageEnd = (budget: number, from: number, end: number, cost: (i: number) => number) => {
  let used = 0
  let i = from
  while (i < end) {
    const c = cost(i)
    if (i > from && used + c > budget) break
    used += c
    i += 1
  }
  return i
}
/** The start of the page that ends just before `from`: as many of the items before it as fit the budget, and always one. */
export const pageStart = (budget: number, from: number, cost: (i: number) => number) => {
  let used = 0
  let i = from
  while (i > 0) {
    const c = cost(i - 1)
    if (i < from && used + c > budget) break
    used += c
    i -= 1
  }
  return i
}
// ── The list's own window ────────────────────────────────────────────────────────────────────

/**
 * Where the commit list's window stands: the row at its top, and how many lines of that row are
 * scrolled above it. Only a row taller than one line, the selected one with its card unfolded,
 * is ever scrolled into; any other row is one step.
 */
export type ListScroll = { from: number; into: number }

/**
 * Moves the list's window `by` lines, negative toward the newest commit, a line at a time so a
 * tall row is scrolled through rather than jumped over. `heightOf` is a row's height in lines,
 * and `last` is the furthest row that may stand at the top.
 */
export const scrollList = (at: ListScroll, by: number, heightOf: (i: number) => number, last: number): ListScroll => {
  let { from, into } = at
  const steps = Math.min(Math.abs(Math.trunc(by)), 1000)
  for (let s = 0; s < steps; s++) {
    if (by > 0) {
      if (into + 1 < heightOf(from)) into += 1
      else if (from < last) {
        from += 1
        into = 0
      } else break
    } else if (into > 0) into -= 1
    else if (from > 0) {
      from -= 1
      into = Math.max(0, heightOf(from) - 1)
    } else break
  }
  return { from, into }
}

const kidsOf = (children: unknown): unknown[] =>
  Array.isArray(children) ? children.flatMap(kidsOf) : children === null || children === undefined || typeof children === 'boolean' ? [] : [children]
const textOf = (node: unknown): string =>
  typeof node === 'string' || typeof node === 'number' ? String(node) : node && typeof node === 'object' ? kidsOf((node as { children?: unknown }).children).map(textOf).join('') : ''

/**
 * About how many lines a drawn piece takes `columns` wide: a Text its lines, wrapped where it
 * wraps; a Button one; a column Box its children and the gaps between them; a row Box its
 * tallest child; and each Box its padding, margin and border. It is the terminal's count. The
 * list scrolls through the selected row's card by it, so a card it counts short loses its last
 * lines to a scroll and one it counts long only pauses the scroll for a line or two.
 */
export const rowsOf = (node: unknown, columns: number): number => {
  if (typeof node === 'string' || typeof node === 'number') return String(node).split('\n').length
  if (!node || typeof node !== 'object') return 0
  const el = node as { type?: string; props?: Record<string, unknown>; children?: unknown }
  const p = el.props ?? {}
  if (p.display === 'none' || p.position === 'absolute') return 0
  const wide = Math.max(1, columns)
  if (el.type === 'Text') {
    const lines = textOf(el).split('\n')
    return p.wrap === 'wrap' ? lines.reduce((n, line) => n + Math.max(1, Math.ceil(line.length / wide)), 0) : lines.length
  }
  if (el.type !== 'Box') return 1
  const num = (...keys: string[]) => {
    for (const k of keys) if (typeof p[k] === 'number') return p[k] as number
    return 0
  }
  const border = typeof p.borderStyle === 'string' && p.borderStyle !== '' ? 1 : 0
  const across = num('paddingLeft', 'paddingX', 'padding') + num('paddingRight', 'paddingX', 'padding') + border * 2
  const kids = kidsOf(el.children).map(k => rowsOf(k, wide - across))
  const inner = p.flexDirection === 'column'
    ? kids.reduce((a, b) => a + b, 0) + Math.max(0, kids.length - 1) * num('rowGap', 'gap')
    : Math.max(0, ...kids)
  const own = typeof p.height === 'number'
    ? p.height
    : inner + num('paddingTop', 'paddingY', 'padding') + num('paddingBottom', 'paddingY', 'padding') + border * 2
  return own + num('marginTop', 'marginY', 'margin') + num('marginBottom', 'marginY', 'margin')
}

/** The same row for a terminal: a mark in the commit's lane and a bar in each lane passing by. */
export const cellText = (row: Row, lanes: number) => {
  let out = ''
  for (let i = 0; i < lanes; i++) {
    out += i === row.lane ? (row.commit.hash === UNCOMMITTED ? '○' : '●') : row.before[i] && !row.ins.includes(i) ? '│' : ' '
    out += ' '
  }
  return out
}

// ── Actions ──────────────────────────────────────────────────────────────────────────────────

export type Action = {
  id: string
  label: string
  /** The heading its button sits under in a commit's panel; actions without one share the target's row. */
  group?: 'commit' | 'current' | 'reset'
  /** Rewrites, deletes or discards: drawn in red, and its confirmation says what is lost. */
  isDanger?: boolean
  /** A name the person types first: a new branch, a tag. */
  asks?: string
  /** The git commands, in order; each a list of arguments after `git`. */
  commands: (input: string) => string[][]
}

const short = (hash: string) => hash.slice(0, 7)
/** A branch or tag name git will take, and that cannot be read as an option. */
export const isRefName = (name: string) =>
  /^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$/.test(name) && !/\.\.|\/\/|\/$|\.lock$|@\{/.test(name)

/** A git operation that stopped half way, usually on a conflict, and waits to be continued or aborted. */
export type Operation = 'merge' | 'cherry-pick' | 'revert' | 'rebase'
/** What an action needs to know of the repository. The optional facts are left out only by callers that do not have them: every action is then offered. */
export type Ctx = {
  branch: string | null
  remotes: readonly string[]
  head?: string | null
  commits?: readonly Commit[]
  refs?: readonly Ref[]
  changes?: readonly Change[]
  /** The branch the current one pulls from, `origin/main`; null where it has none. */
  upstream?: string | null
  operation?: Operation | null
  /** Each remote's default branch, `origin/main`. */
  defaults?: readonly string[]
}

/** Read beside the log: the upstream, an operation in progress, each remote's default branch. */
export const EXTRA_QUERIES: readonly (readonly string[])[] = [
  ['rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{upstream}'],
  ['rev-parse', '-q', '--verify', 'REBASE_HEAD'],
  ['rev-parse', '-q', '--verify', 'MERGE_HEAD'],
  ['rev-parse', '-q', '--verify', 'CHERRY_PICK_HEAD'],
  ['rev-parse', '-q', '--verify', 'REVERT_HEAD'],
  ['for-each-ref', '--format=%(symref:short)', 'refs/remotes/*/HEAD'],
  // The upstream's side first: commits only it has, a tab, commits only the branch has.
  ['rev-list', '--left-right', '--count', '@{upstream}...HEAD'],
]
type Ran = { exitCode: number; stdout: string }
export const parseExtras = (ran: readonly Ran[]): { upstream: string | null; operation: Operation | null; defaults: string[]; ahead: number; behind: number } => {
  const ok = (i: number) => ran[i]?.exitCode === 0 && (ran[i]?.stdout ?? '').trim() !== ''
  const [behind = 0, ahead = 0] = ok(0) && ok(6) ? (ran[6]?.stdout ?? '').trim().split(/\s+/).map(x => Number(x) || 0) : []
  return {
    ahead,
    behind,
    upstream: ok(0) ? (ran[0]?.stdout ?? '').trim() : null,
    operation: ok(1) ? 'rebase' : ok(2) ? 'merge' : ok(3) ? 'cherry-pick' : ok(4) ? 'revert' : null,
    defaults: ok(5) ? (ran[5]?.stdout ?? '').split('\n').map(l => l.trim()).filter(Boolean) : [],
  }
}
export const readExtras = (run: (args: string[]) => Ran) => parseExtras(EXTRA_QUERIES.map(q => run([...q])))

/** Every listed commit that is HEAD or behind it; null where HEAD is not among the commits listed, so nothing can be said. */
export const reachable = (commits: readonly Commit[], head: string | null | undefined): Set<string> | null => {
  if (!head) return null
  const byHash = new Map(commits.filter(c => !c.stash).map(c => [c.hash, c]))
  if (!byHash.has(head)) return null
  const seen = new Set<string>()
  const todo = [head]
  while (todo.length) {
    const h = todo.pop() as string
    if (seen.has(h)) continue
    seen.add(h)
    for (const p of byHash.get(h)?.parents ?? []) todo.push(p)
  }
  return seen
}

// While an operation waits, git refuses whatever would move HEAD or touch the working tree:
// only these are offered, beside continuing or aborting the operation itself.
const DURING = new Set(['commit:branch', 'commit:tag', 'head:rename', 'head:push', 'head:delete', 'head:delete-force', 'remote:delete', 'tag:push', 'tag:delete', 'stash:drop', 'repo:fetch', 'repo:push'])

/**
 * What can be done to a commit, a branch, a tag, the working tree or the repository as it stands:
 * an action git is known to refuse here is not offered.
 */
export const actionsFor = (t: Target, ctx: Ctx): Action[] => {
  const all = offered(t, ctx)
  return ctx.operation && t.kind !== 'operation' ? all.filter(a => DURING.has(`${t.kind}:${a.id}`)) : all
}

const offered = (t: Target, ctx: Ctx): Action[] => {
  const onto = ctx.branch ?? 'HEAD'
  const hasRemote = ctx.remotes.length > 0
  const remote = ctx.remotes.includes('origin') ? 'origin' : (ctx.remotes[0] ?? 'origin')
  const one = (id: string, label: string, args: string[], more: Partial<Action> = {}): Action => ({ id, label, commands: () => [args], ...more })
  const when = (cond: boolean, ...actions: Action[]) => (cond ? actions : [])
  // Behind HEAD already: merging, rebasing onto or cherry-picking it would do nothing, or stop on an empty commit.
  const behind = ctx.commits ? reachable(ctx.commits, ctx.head) : null
  const isBehind = (hash: string | undefined) => !!hash && !!behind && behind.has(hash)
  const tipOf = (kind: Ref['kind'], name: string) => ctx.refs?.find(x => x.kind === kind && x.name === name)?.hash
  if (t.kind === 'operation') {
    const op = ctx.operation
    if (!op) return []
    return [one('continue', `Continue the ${op}`, [op, '--continue']), one('abort', `Abort the ${op}`, [op, '--abort'], { isDanger: true })]
  }
  if (t.kind === 'commit') {
    const h = t.hash
    const isHead = h === ctx.head
    const done = isBehind(h)
    // A merge is picked or reverted as its difference from its first parent.
    const mainline = (ctx.commits?.find(c => c.hash === h)?.parents.length ?? 1) > 1 ? ['-m', '1'] : []
    return [
      ...when(!(isHead && ctx.branch === null), one('checkout', 'Checkout', ['checkout', h], { group: 'commit' })),
      { id: 'branch', label: 'Branch…', group: 'commit', asks: 'Branch name', commands: name => [['branch', name, h]] },
      { id: 'branch-checkout', label: 'Branch and checkout…', group: 'commit', asks: 'Branch name', commands: name => [['checkout', '-b', name, h]] },
      { id: 'tag', label: 'Tag…', group: 'commit', asks: 'Tag name', commands: name => [['tag', name, h]] },
      ...when(!done, one('cherry-pick', 'Cherry pick', ['cherry-pick', ...mainline, h], { group: 'commit' })),
      // Only what HEAD's history holds can be undone on it.
      ...when(!behind || done, one('revert', 'Revert', ['revert', '--no-edit', ...mainline, h], { group: 'commit' })),
      ...when(!done, one('merge', `Merge into ${onto}`, ['merge', '--no-edit', '--autostash', h], { group: 'current' })),
      ...when(!done, one('rebase', `Rebase ${onto} onto this`, ['rebase', '--autostash', h], { group: 'current', isDanger: true })),
      ...when(
        !isHead,
        one('reset-soft', 'Soft', ['reset', '--soft', h], { group: 'reset' }),
        one('reset-mixed', 'Mixed', ['reset', '--mixed', h], { group: 'reset' }),
        one('reset-hard', 'Hard', ['reset', '--hard', h], { group: 'reset', isDanger: true }),
      ),
    ]
  }
  if (t.kind === 'head') {
    const b = t.name
    const isCurrent = b === ctx.branch
    const done = isBehind(tipOf('head', b))
    return [
      ...when(!isCurrent, one('checkout', 'Checkout', ['checkout', b])),
      { id: 'rename', label: 'Rename…', asks: 'New name', commands: (name: string) => [['branch', '-m', b, name]] },
      ...when(!isCurrent && !done, one('merge', `Merge into ${onto}`, ['merge', '--no-edit', '--autostash', b]), one('rebase', `Rebase ${onto} onto this`, ['rebase', '--autostash', b], { isDanger: true })),
      // Git deletes a branch without force only once it is merged; where it is known not to be, only the forced delete is offered.
      ...when(!isCurrent && (!behind || done), one('delete', 'Delete', ['branch', '-d', b], { isDanger: true })),
      ...when(!isCurrent, one('delete-force', 'Force delete', ['branch', '-D', b], { isDanger: true })),
      ...when(hasRemote, one('push', `Push to ${remote}`, ['push', '-u', remote, b])),
    ]
  }
  if (t.kind === 'remote') {
    const slash = t.name.indexOf('/')
    const r = t.name.slice(0, slash)
    const b = t.name.slice(slash + 1)
    const done = isBehind(tipOf('remote', t.name))
    const hasLocal = !!ctx.refs?.some(x => x.kind === 'head' && x.name === b)
    // A remote refuses to delete its default branch.
    const isDefault = !!ctx.defaults && (ctx.defaults.includes(t.name) || (!ctx.defaults.some(d => d.startsWith(`${r}/`)) && (b === 'main' || b === 'master')))
    return [
      ...when(!hasLocal, one('checkout', 'Checkout as local branch', ['checkout', '--track', t.name])),
      ...when(!done, one('merge', `Merge into ${onto}`, ['merge', '--no-edit', '--autostash', t.name])),
      // A merge, said outright: without it git refuses to pull a branch that has diverged from this one.
      ...when(!done, one('pull', `Pull into ${onto}`, ['pull', '--no-rebase', '--no-edit', '--autostash', r, b])),
      ...when(!isDefault, one('delete', 'Delete on remote', ['push', r, '--delete', b], { isDanger: true })),
    ]
  }
  if (t.kind === 'tag') {
    return [...when(hasRemote, one('push', `Push to ${remote}`, ['push', remote, `refs/tags/${t.name}`])), one('delete', 'Delete', ['tag', '-d', t.name], { isDanger: true })]
  }
  if (t.kind === 'stash') {
    return [
      one('apply', 'Apply', ['stash', 'apply', t.name]),
      one('pop', 'Pop', ['stash', 'pop', t.name]),
      { id: 'branch', label: 'Branch from it…', asks: 'Branch name', commands: name => [['stash', 'branch', name, t.name]] },
      one('drop', 'Drop', ['stash', 'drop', t.name], { isDanger: true }),
    ]
  }
  if (t.kind === 'changes') {
    const hasTracked = !ctx.changes || ctx.changes.some(c => !c.code.includes('?'))
    const hasUntracked = !ctx.changes || ctx.changes.some(c => c.code.includes('?'))
    return [
      one('stash', 'Stash', ['stash', 'push', '--include-untracked']),
      ...when(hasTracked, one('discard', 'Discard tracked changes', ['reset', '--hard', 'HEAD'], { isDanger: true })),
      ...when(hasUntracked, one('clean', 'Delete untracked files', ['clean', '-fd'], { isDanger: true })),
    ]
  }
  // The repository. Where the upstream is not known, the plain commands are offered as before.
  if (ctx.upstream === undefined) return [one('fetch', 'Fetch', ['fetch', '--all', '--prune']), one('pull', 'Pull', ['pull']), one('push', 'Push', ['push'])]
  return [
    ...when(hasRemote, one('fetch', 'Fetch', ['fetch', '--all', '--prune'])),
    // A merge, said outright, as for a remote branch: git refuses a plain pull of a diverged branch.
    ...when(!!ctx.upstream, one('pull', 'Pull', ['pull', '--no-rebase', '--no-edit', '--autostash'])),
    ...when(hasRemote && !!ctx.branch, ctx.upstream ? one('push', 'Push', ['push']) : one('push', 'Push', ['push', '-u', remote, ctx.branch ?? 'HEAD'])),
  ]
}

/** What git said when it refused, in a line or two: its hints and prefixes left out. */
export const explain = (stderr: string, stdout = ''): string =>
  (stderr.trim() || stdout.trim())
    .split('\n')
    .map(l => plain(l.replace(/^(error|fatal|remote|warning):\s*/i, '').replace(/\s+/g, ' ')).trim())
    .filter(l => l && !/^hint:/i.test(l) && l !== 'Aborting')
    .slice(0, 3)
    .join(' ')

/** True where git refused before changing anything: said as a warning, not as a failure. */
export const isRefusal = (why: string) =>
  /would be overwritten|unstaged changes|uncommitted changes|not fully merged|already exists|resolve your current index|unmerged files|no upstream|no tracking information|not something we can merge|nothing to commit/i.test(why)

/** A target in a few words, for the line that asks whether to run an action on it. */
export const targetName = (t: Target) =>
  t.kind === 'commit' ? `commit ${short(t.hash)}` : t.kind === 'changes' ? 'the working tree' : t.kind === 'repo' ? 'the repository' : t.kind === 'operation' ? 'what is in progress' : `${t.kind === 'head' ? 'branch' : t.kind === 'remote' ? 'remote branch' : t.kind === 'stash' ? 'stash' : 'tag'} ${t.name}`

/** The commands as the person would type them. */
export const commandLine = (commands: readonly string[][]) => commands.map(c => `git ${c.join(' ')}`).join(' && ')

/** How long ago, in one short unit. */
export const fmtAgo = (seconds: number) => {
  const s = Math.max(0, Math.round(seconds))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.round(s / 60)} min`
  if (s < 86400) return `${Math.round(s / 3600)} h`
  if (s < 86400 * 60) return `${Math.round(s / 86400)} d`
  if (s < 86400 * 365) return `${Math.round(s / (86400 * 30))} mo`
  return `${Math.round(s / (86400 * 365))} y`
}

/** Whether a commit matches what was typed in the find box: its subject, author or hash. */
export const matches = (c: Commit, query: string) => {
  const q = query.trim().toLowerCase()
  return !q || c.subject.toLowerCase().includes(q) || c.author.toLowerCase().includes(q) || c.hash.startsWith(q)
}

/** Whether a shell command is likely to have changed what the graph shows. */
export const touchesGit = (command: string) => /(^|[\s;&|(])git\s/.test(command)

/** The author, age and commit columns' widths in cells, for each preset. */
export const COLUMNS = {
  compact: { author: 12, age: 7, commit: 9 },
  normal: { author: 18, age: 8, commit: 9 },
  wide: { author: 28, age: 9, commit: 10 },
} as const
export const nextColumns = (now: keyof typeof COLUMNS): keyof typeof COLUMNS => (now === 'compact' ? 'normal' : now === 'normal' ? 'wide' : 'compact')

/**
 * The columns that fit a panel `body` cells wide, beside a graph `graph` cells wide: the preset's
 * widths where there is room, with the description always keeping at least `DESCRIPTION_MIN`.
 * As the panel narrows the author goes first (to its compact width, then altogether), then the
 * commit hash, then the age; 0 means the column is left out.
 */
export const DESCRIPTION_MIN = 34
export const fitColumns = (preset: keyof typeof COLUMNS, body: number, graph: number) => {
  const want = COLUMNS[preset] ?? COLUMNS.normal
  const room = body - graph - DESCRIPTION_MIN
  const age = room >= want.age ? want.age : 0
  const commit = age > 0 && room >= age + want.commit ? want.commit : 0
  const left = room - age - commit
  const author = commit === 0 ? 0 : left >= want.author ? want.author : left >= COLUMNS.compact.author ? COLUMNS.compact.author : 0
  return { author, age, commit }
}
