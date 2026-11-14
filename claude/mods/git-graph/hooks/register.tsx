// Git graph: a panel that draws the repository's commits as a graph, with a branch filter, a
// find box, a row for uncommitted changes, and git actions on what is selected. Every action is
// shown as the command it will run and waits for a yes before it runs.

import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, RenderChildren } from 'claude-code'

import type { Detail, Pending, Repo, Target, Toast, View, Worktree } from '../types'
import {
  EXTRA_QUERIES, LOG_FORMAT, REF_FORMAT, UNCOMMITTED, actionsFor, explain, isRefusal, parseExtras, cellSvg, cellText, cellWidth, commandLine, fmtAgo, isRefName, laneColor, lanesOf, layout,
  fitColumns, matches, nextColumns, pageEnd, pageStart, parseLog, parseNumstat, parseRefs, parseStashes, parseStatus, parseWorktrees, plain, STASH_FORMAT, targetName, touchesGit, withStashes, ROWS_BUDGET_MIN, TREE_BUDGET, rowsOf, scrollList, sizeOf,
} from './core'
import type { Action, Row } from './core'

const PANE = 'git-graph'
const TITLE = 'Git graph'
const PAGE = 150
// The branch filter lists this many branches at most: each is part of what the panel holds.
const BRANCHES_MAX = 200
// A body cell's width in CSS pixels on the desktop, as measured for the project map: a Box is
// sized in cells, and the graph's column needs a width or its drawing collapses to nothing.
const CELL_PX = 9.5
// One gap for the whole panel. A cell is about twice as tall as it is wide, so two cells across
// are the same distance as one row down: GX between things side by side, GY between things
// stacked, and both where a row of things wraps. Toolbar groups stand twice as far apart.
const GX = 2
const GY = 1
// The rows at the bottom of the panel's window that the pinned toast may take.
const PIN_ROWS = 8
// The fewest rows a panel shows for the toolbar to stay put over a list that scrolls by itself.
// A shorter panel has no room for both, and scrolls as a whole, toolbar and all.
const PIN_MIN = 16
// Within this many rows of the end of the commits read so far, the next ones are read from git.
const READ_AHEAD = 60
// The list scrolls under a toolbar that stays put. The app hands the panel its wheel only while
// its window can move that way, at the edges not at all. So the drawing is two rows taller than
// the window, and after each tick the window is put back on the row between them, with room to
// move both ways. The desktop moves the window before the mod is asked, so the panel is drawn as
// far down as the window stands and stays in place. Of the three ways tried, this was the
// smoothest: a window that drifts with the wheel jerked more, and one that never moves got no
// wheel at all.
const PINNED_LIST = true
const SCROLL_SLACK = 2
const SCROLL_PARK = 1
// Tokyo Night, as the other mods use it.
const C = { card: '#24283b', soft: '#a9b1d6', track: '#3b4261', label: '#565f89', subtle: '#737aa2', text: '#c0caf5', blue: '#7aa2f7', green: '#9ece6a', amber: '#e0af68', purple: '#bb9af7', red: '#f7768e', cyan: '#7dcfff' }

// A toast's mark and colour, by how serious it is.
const TOAST_LOOK = {
  ok: { mark: '✓', color: C.green },
  info: { mark: 'i', color: C.blue },
  warn: { mark: '!', color: C.amber },
  error: { mark: '✕', color: C.red },
} as const

const VIEW: View = { branch: '', showRemotes: true, showTags: true, showWorktrees: true, find: '', limit: PAGE, from: 0, into: 0, columns: 'normal' }
// The column preset is the person's choice, kept between sessions.
const COLUMNS_KEY = 'columns'

// null until the session is known to be in a git repository: the other mods read this too, and
// draw the graph's toggle only while it is true or false.
const isOpen = atom({ plugin: 'git-graph', key: 'isOpen' } as const, null)
const repo = atom({ plugin: 'git-graph', key: 'repo' } as const, null)
const view = atom({ plugin: 'git-graph', key: 'view' } as const, VIEW)
const selected = atom({ plugin: 'git-graph', key: 'selected' } as const, null)
const pending = atom({ plugin: 'git-graph', key: 'pending' } as const, null)
const toast = atom({ plugin: 'git-graph', key: 'toast' } as const, null)
const isBusy = atom({ plugin: 'git-graph', key: 'isBusy' } as const, false)
const facts = atom({ plugin: 'git-graph', key: 'detail' } as const, null)
const mark = atom({ plugin: 'git-graph', key: 'compare' } as const, null)
// True where a status-band mod new enough to draw the graph's toggle is loaded: this mod then
// adds no row to the band.
const bandCarriesGraph = atom({ plugin: 'status-band', key: 'carriesGraph' } as const, false)

// Git, never waiting on an editor: a merge or revert that would open one takes the default message.
const git = ($: EngineInterface, cwd: string, args: readonly string[], timeoutMs = 15000) =>
  $.process.run(['git', '-c', 'core.editor=true', ...args], { cwd, timeoutMs })

// Reads the repository for the view as it stands. Where the session is not in one, there is no
// panel and no toggle; where it is, the panel starts hidden.
const load = async ($: EngineInterface) => {
  const dir = await $.session.root().catch(() => '')
  const top = dir ? await git($, dir, ['rev-parse', '--show-toplevel']).catch(() => null) : null
  if (!top || top.exitCode !== 0) {
    await update($, repo, () => null)
    if (((await read($, isOpen)) ?? null) !== null) {
      await update($, isOpen, () => null)
      await $.ui.close({ id: PANE }).catch(() => undefined)
    }
    return
  }
  const root = top.stdout.trim()
  const v = (await read($, view)) ?? VIEW
  // One branch alone, or every branch with the tags and remote branches the view has on.
  // The other worktrees first: one on a detached HEAD has commits no branch reaches, and the
  // log is asked for them by name.
  const listed = await git($, root, ['worktree', 'list', '--porcelain'])
  const worktrees = listed.exitCode === 0 ? parseWorktrees(listed.stdout).filter(w => w.path !== root) : []
  const apart = (v.showWorktrees ?? true) ? worktrees.filter(w => !w.branch && !w.isPrunable).map(w => w.head) : []
  const revs = v.branch ? [v.branch] : ['--branches', ...(v.showTags ? ['--tags'] : []), ...(v.showRemotes ? ['--remotes'] : []), 'HEAD', ...apart]
  const [log, refs, head, branch, status, remotes, stashed, ...extras] = await Promise.all([
    git($, root, ['log', `--format=${LOG_FORMAT}`, '--date-order', '-n', String(v.limit + 1), ...revs, '--']),
    git($, root, ['for-each-ref', `--format=${REF_FORMAT}`]),
    git($, root, ['rev-parse', 'HEAD']),
    git($, root, ['symbolic-ref', '-q', '--short', 'HEAD']),
    git($, root, ['status', '--porcelain']),
    git($, root, ['remote']),
    git($, root, ['stash', 'list', `--format=${STASH_FORMAT}`]),
    ...EXTRA_QUERIES.map(q => git($, root, q)),
  ])
  // A repository with no commit yet has no log: an empty graph, not an error.
  const commits = log.exitCode === 0 ? parseLog(log.stdout) : []
  const next: Repo = {
    root,
    head: head.exitCode === 0 ? head.stdout.trim() : null,
    branch: branch.exitCode === 0 ? branch.stdout.trim() || null : null,
    commits: withStashes(commits.slice(0, v.limit), stashed.exitCode === 0 ? parseStashes(stashed.stdout) : []),
    refs: refs.exitCode === 0 ? parseRefs(refs.stdout) : [],
    changes: status.exitCode === 0 ? parseStatus(status.stdout) : [],
    remotes: remotes.exitCode === 0 ? remotes.stdout.split('\n').filter(Boolean) : [],
    worktrees,
    hasMore: commits.length > v.limit,
    ...parseExtras(extras),
  }
  await update($, repo, () => next)
  if (((await read($, isOpen)) ?? null) === null) {
    // The panel never opens by itself: a session starts with it hidden, whatever it was last
    // time, and the toggle or /graph shows it.
    await update($, isOpen, () => false)
    await $.ui.close({ id: PANE }).catch(() => undefined)
  }
}
// Reads what the selected commit's panel shows: its full message, and the files it changed with
// their line counts, or, where another commit is marked to compare, the files that differ
// between the two.
const loadDetail = async ($: EngineInterface, hash: string | null) => {
  const r = await read($, repo)
  if (!r || !hash || hash === UNCOMMITTED) return void (await update($, facts, () => null))
  const marked = await read($, mark)
  const against = marked && marked !== hash ? marked : null
  const commit = r.commits.find(c => c.hash === hash)
  const [body, stat] = await Promise.all([
    git($, r.root, ['log', '-1', '--format=%B', hash]),
    against
      ? git($, r.root, ['diff', '--numstat', against, hash])
      : // A stash is a merge of its own making: what it holds is its difference from the commit under it.
        commit?.stash
        ? git($, r.root, ['diff', '--numstat', `${hash}^1`, hash])
        : git($, r.root, ['diff-tree', '--no-commit-id', '--numstat', '-r', '--root', hash]),
  ])
  const next: Detail = { hash, body: body.exitCode === 0 ? plain(body.stdout).trim() : '', files: stat.exitCode === 0 ? parseNumstat(stat.stdout) : [], against }
  // Only if it is still the one selected: a slower answer for an earlier press is dropped.
  if ((await read($, selected)) === hash) await update($, facts, () => next)
}

// Reads again only while the panel is shown: nothing is run for a graph nobody is looking at.
const refresh = async ($: EngineInterface) => {
  if ((await read($, isOpen)) === true) await load($).catch(() => undefined)
}

const setOpen = async ($: EngineInterface, open: boolean) => {
  await update($, isOpen, () => open)
}
const show = async ($: EngineInterface) => {
  await setOpen($, true)
  await load($).catch(() => undefined)
  const opened = await $.ui.open({ id: PANE, title: TITLE })
  // The panel is not drawn, so its own toast would not be seen: the app's says it.
  if (!opened.isPlaced) $.ui.toast('Git graph: no room for the panel here yet; it opens when there is.')
}
const hide = async ($: EngineInterface) => {
  await setOpen($, false)
  await $.ui.close({ id: PANE }).catch(() => undefined)
}
const toggle = async ($: EngineInterface) => ((await read($, isOpen)) === true ? hide($) : show($))

const NO_REPO = 'This session is not in a git repository, so there is no graph to show.'

// A press of the toggle another mod draws: show or hide the panel, where there is a repository.
const onGraphPress = async <E, R>($: EngineInterface, e: E, next: (e: E) => Promise<R>) => {
  const set = await next(e)
  if (((await read($, isOpen)) ?? null) !== null) await toggle($).catch(() => undefined)
  return set
}

// How long a toast stays; an error stays until it is dismissed or replaced.
const TOAST_MS = { ok: 5000, info: 5000, warn: 10000, error: 0 } as const
let toastId = 0
// Shows a message at the bottom of the panel, in place of the one before it.
const say = async ($: EngineInterface, level: Toast['level'], title: string, text = '', stays = false) => {
  toastId += 1
  const id = Date.now() * 100 + (toastId % 100)
  await update($, toast, (): Toast => ({ id, level, title: plain(title), text: plain(text) }))
  const ms = stays ? 0 : TOAST_MS[level]
  if (ms > 0) $.clock.after(ms, () => void update($, toast, old => (old?.id === id ? null : old)).catch(() => undefined))
}
const dismiss = ($: EngineInterface) => update($, toast, () => null)

// An action picked: it waits for a name where it needs one, and always for a yes.
const pick = async ($: EngineInterface, target: Target, action: Action) => {
  await update($, pending, (): Pending => ({ target, action: action.id, input: '', stage: action.asks ? 'name' : 'confirm' }))
}

// Runs the pending action's commands in order, stopping at the first that fails, then reads the
// repository again. What happened is said in a toast: done, refused with nothing changed,
// stopped on a conflict, or failed.
const runPending = async ($: EngineInterface) => {
  const p = await read($, pending)
  const r = await read($, repo)
  if (!p || !r || (await read($, isBusy)) === true) return
  const action = actionsFor(p.target, r).find(a => a.id === p.action)
  if (!action) return
  const commands = action.commands(p.input)
  const label = action.label.replace(/…$/, '')
  await update($, isBusy, () => true)
  await update($, pending, () => null)
  await say($, 'info', `${label}: running`, commandLine(commands), true)
  let failed: { args: string[]; why: string } | null = null
  let threw = ''
  try {
    for (const args of commands) {
      const ran = await git($, r.root, args, 120000)
      if (ran.exitCode !== 0) {
        failed = { args, why: explain(ran.stderr, ran.stdout) || `git ended with exit code ${ran.exitCode}.` }
        break
      }
    }
  } catch (err) {
    threw = String(err)
  }
  await update($, isBusy, () => false)
  await load($).catch(() => undefined)
  await loadDetail($, await read($, selected)).catch(() => undefined)
  const now = await read($, repo)
  if (threw) await say($, 'error', `${label}: git could not be run`, threw)
  else if (!failed) await say($, 'ok', `${label}: done`, commandLine(commands))
  else if (now?.operation && !r.operation) await say($, 'warn', `${label} stopped: the ${now.operation} needs you`, `${failed.why} Resolve it in the files, then continue or abort the ${now.operation} from the top of the graph.`)
  else if (isRefusal(failed.why)) await say($, 'warn', `${label}: git refused, nothing was changed`, failed.why)
  else await say($, 'error', `${label} failed`, `${failed.why} (git ${failed.args.join(' ')})`)
}

const sameTarget = (a: Target, b: Target) => JSON.stringify(a) === JSON.stringify(b)
// The commit list as it was last drawn, for the scroll hook to move its window over: how many
// rows it has, which one is unfolded and how tall that one is, the furthest row that may stand
// at the top, where its window stood, and whether the toolbar stays put over it.
let shape = { count: 0, selAt: -1, selRows: 1, last: 0, from: 0, into: 0, offset: 0, isPinned: false }
let isReading = false
// Near the end of the commits read so far, the next ones are read from git: the list goes on as
// it is scrolled, with nothing to press.
const readOlder = async ($: EngineInterface) => {
  const r = await read($, repo)
  if (!r?.hasMore || isReading || shape.count - shape.from > READ_AHEAD) return
  isReading = true
  try {
    await update($, view, old => ({ ...(old ?? VIEW), limit: (old ?? VIEW).limit + PAGE }))
    await load($)
  } finally {
    isReading = false
  }
}

const targetKey = (t: Target) => (t.kind === 'commit' ? `c:${t.hash}` : t.kind === 'changes' || t.kind === 'repo' || t.kind === 'operation' ? t.kind : `${t.kind}:${t.name}`)

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'graph', description: 'Show or hide the git graph panel; `/graph refresh` reads the repository again', argumentHint: '[refresh]' })
    const kept = await $.store.get(COLUMNS_KEY).catch(() => null)
    const columns: View['columns'] | null = kept === 'compact' || kept === 'normal' || kept === 'wide' ? kept : null
    if (columns) await update($, view, (old): View => ({ ...(old ?? VIEW), columns }))
    // Not awaited: reading a large repository must not hold up the session's start.
    void load($).catch(() => undefined)
    return next(e)
  })

  on('command.run', { command: 'graph' }, async ($, e) => {
    // Read first: the session may have moved into a repository, or out of one.
    await load($).catch(() => undefined)
    if (((await read($, isOpen)) ?? null) === null) return { text: NO_REPO }
    if (String(e.args ?? '').trim() === 'refresh') return { text: 'Git graph read again.' }
    await toggle($)
    return { text: (await read($, isOpen)) === true ? 'Git graph shown.' : 'Git graph hidden. /graph shows it again.' }
  })

  // The status band and the session's rule draw the graph's toggle and count its presses. A
  // press toggles the panel here, silently: nothing is typed into the prompt or the transcript.
  on('state.set', { plugin: 'status-band', key: 'graphPress' }, onGraphPress)
  on('state.set', { plugin: 'session-tint', key: 'graphPress' }, onGraphPress)

  // Closed from the panel's own mark or key: remember it as hidden.
  on('ui.close', async ($, e, next) => {
    // Not when the mod itself closed it for want of a repository: that is not the person's choice.
    if (e.id === PANE && (await read($, isOpen)) === true) await setOpen($, false).catch(() => undefined)
    return next(e)
  })

  // The session may have moved to another folder, and commits may have been made outside it.
  on('prompt.submit', async ($, e, next) => {
    void load($).catch(() => undefined)
    return next(e)
  })

  // A git command the model ran has most likely changed the graph: show it at once.
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const ran = await next(e)
    try {
      const command = (e as unknown as { command?: unknown }).command
      if (typeof command === 'string' && touchesGit(command)) await refresh($)
    } catch {
      // The graph just misses this call.
    }
    return ran
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (!e.agentId) void refresh($)
    return done
  })

  // The commit list scrolls under the toolbar by itself. The panel's window stays on its middle
  // slack row, and the list's own window takes the move instead, so the toolbar never scrolls
  // away. A panel too short for that scrolls as a whole, and the list's
  // window moves on only once the panel's has reached its end.
  on('ui.scroll', { component: 'Pane', requestId: PANE }, async ($, e, next) => {
    // A panel too short for a fixed toolbar scrolls as a whole and pages; the mod's own moves of
    // the window (back to its top, below) go through as asked.
    if (!PINNED_LIST || !shape.isPinned || e.origin.kind === 'plugin') return next(e)
    const at = scrollList({ from: shape.from, into: shape.into }, e.by, i => (i === shape.selAt ? shape.selRows : 1), shape.last)
    if (at.from !== shape.from || at.into !== shape.into) {
      shape = { ...shape, ...at }
      await update($, view, old => ({ ...(old ?? VIEW), ...at }))
    }
    await readOlder($).catch(() => undefined)
    // The window goes back to the middle row, not to where the tick took it: left at an edge, the
    // app would hand the panel no wheel that way.
    return next({ ...e, offset: SCROLL_PARK })
  })

  // The toggle, drawn here only where no status band carries it.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    if ((await read($, bandCarriesGraph).catch(() => false)) === true) return next(e)
    if (((await read($, isOpen)) ?? null) === null) return next(e)
    const { Box, Button } = $.ui.resolve(e)
    const beneath = await next(e)
    const below = beneath.type === 'engine' ? null : beneath
    const open = (await read($, isOpen)) === true
    return (
      <Box flexDirection="column" width="100%">
        {below}
        <Box width="100%" justifyContent="flex-end">
          <Button key="graph" plain label={open ? 'hide graph' : 'graph'} onPress={() => toggle($)} />
        </Box>
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const Svg = e.surface === 'terminal' ? undefined : $.ui.resolve(e).Svg
    const Input = e.surface === 'mobile' ? undefined : $.ui.resolve(e).Input
    const Select = e.surface === 'mobile' ? undefined : $.ui.resolve(e).Select
    const r = await read($, repo)
    if (!r) return <Text color={C.label}>{NO_REPO}</Text>
    const v = (await read($, view)) ?? VIEW
    const sel = await read($, selected)
    const note = await read($, toast)
    const look = note ? TOAST_LOOK[note.level] : null
    const p = await read($, pending)
    const now = Math.round((await $.clock.now().catch(() => 0)) / 1000)

    // A change of what is shown starts again at the newest commit.
    const setView = async (change: Partial<View>) => {
      await update($, view, old => ({ ...(old ?? VIEW), from: 0, into: 0, ...change }))
      await load($).catch(() => undefined)
    }
    // A small dim heading over a group of controls, or beside a row of them.
    const caption = (text: string) => <Text color={C.label}>{text.toUpperCase()}</Text>
    // An action as one of the app's own buttons. A destructive one is marked in red before it:
    // a button's own text cannot be coloured.
    // Pressing a row selects it, or folds it again; its panel's facts are then read.
    const select = async (hash: string) => {
      const next = sel === hash ? null : hash
      await update($, selected, () => next)
      await update($, pending, () => null)
      await update($, facts, old => (old?.hash === next ? old : null))
      await loadDetail($, next).catch(() => undefined)
    }
    const info = await read($, facts)
    const marked = await read($, mark)
    const markToCompare = async (hash: string | null) => {
      await update($, mark, () => hash)
      await loadDetail($, sel).catch(() => undefined)
    }
    const actionButton = (target: Target, a: Action, isPrimary = false) => (
      <Box key={`a:${targetKey(target)}:${a.id}`} flexShrink={0} alignItems="center">
        {a.isDanger ? <Text color={C.red}>{'● '}</Text> : null}
        <Button key={`act:${targetKey(target)}:${a.id}`} variant={isPrimary ? 'primary' : 'secondary'} label={a.label} onPress={() => pick($, target, a)} />
      </Box>
    )
    // The pending action: the name it needs, then the command it will run and a yes or no.
    const ask = (target: Target) => {
      if (!p || !sameTarget(p.target, target)) return null
      const action = actionsFor(target, r).find(a => a.id === p.action)
      if (!action) return null
      if (p.stage === 'name') {
        if (!Input) return null
        return (
          <Box key="ask" width="100%" alignItems="center" flexWrap="wrap" columnGap={GX} rowGap={GY}>
            <Input
              key="ask-name"
              label={`${action.asks}:`}
              autoFocus
              submitLabel="next"
              onSubmit={async value => {
                const name = value.trim()
                if (!isRefName(name)) return void (await say($, 'warn', 'Not a name git accepts', `"${name}" cannot be used: letters, digits, dots, dashes and slashes, starting with a letter or digit.`))
                await update($, pending, (old): Pending | null => (old ? { ...old, input: name, stage: 'confirm' } : old))
              }}
            />
            <Button key="ask-cancel" variant="secondary" label="Cancel" onPress={() => update($, pending, () => null)} />
          </Box>
        )
      }
      return (
        <Box key="ask" width="100%" flexWrap="wrap" alignItems="center" columnGap={GX} rowGap={GY}>
          <Box flexShrink={1} minWidth={0}>
            <Text color={action.isDanger ? C.red : C.amber} wrap="wrap">
              {`${action.isDanger ? 'This cannot be undone from here. ' : ''}Run ${commandLine(action.commands(p.input))} on ${targetName(target)}?`}
            </Text>
          </Box>
          <Button key="ask-run" variant="primary" label="Run" onPress={() => runPending($)} />
          <Button key="ask-cancel" variant="secondary" label="Cancel" onPress={() => update($, pending, () => null)} />
        </Box>
      )
    }
    // One row of a card: a caption or a coloured name at the left, then that row's buttons.
    const LABEL_W = (e.props.bodyColumns ?? 100) < 70 ? 10 : 14
    const groupRow = (key: string, label: string, color: string | null, target: Target, actions: Action[]) =>
      actions.length === 0 ? null : (
        <Box key={`g:${key}`} width="100%" alignItems="center">
          <Box width={LABEL_W} flexShrink={0}>
            {color ? <Text color={color} bold wrap="truncate">{label}</Text> : caption(label)}
          </Box>
          <Box flexGrow={1} flexShrink={1} minWidth={0} flexWrap="wrap" alignItems="center" columnGap={GX} rowGap={GY}>
            {actions.map(a => actionButton(target, a))}
          </Box>
        </Box>
      )
    // The panel under a selected row: a thin rounded border round a heading, some dim facts,
    // and the rows of buttons; the action being confirmed sits at its foot.
    const card = (key: string, title: string, facts: string, body: RenderChildren[], target: Target, others: Target[] = []) => (
      <Box key={key} width="100%" paddingY={GY}>
        <Box flexDirection="column" width="100%" borderStyle="round" borderColor={C.track} paddingX={GX} paddingY={GY} rowGap={GY}>
          <Box key="title" flexDirection="column" width="100%">
            <Text color={C.text} bold wrap="wrap">{title}</Text>
            {facts ? <Text color={C.subtle} wrap="truncate">{facts}</Text> : null}
          </Box>
          {body}
          {[target, ...others].map(ask)}
        </Box>
      </Box>
    )

    const shownRefs = r.refs.filter(x => x.kind === 'head' || (x.kind === 'remote' ? v.showRemotes : v.showTags))
    const shownTrees: Worktree[] = (v.showWorktrees ?? true) ? (r.worktrees ?? []) : []
    const treeLabel = (w: Worktree) => `⌂ ${w.name}`
    const refColor = (kind: string, name: string) => (kind === 'tag' ? C.amber : kind === 'remote' ? C.cyan : name === r.branch ? C.green : C.blue)

    // The uncommitted changes sit on top as a commit of their own, whose parent is HEAD.
    const list = r.changes.length > 0 && r.head && !v.branch
      ? [{ hash: UNCOMMITTED, parents: [r.head], author: '', at: now, subject: `Uncommitted changes (${r.changes.length})` }, ...r.commits]
      : r.commits
    const finding = v.find.trim() !== ''
    const rows: Row[] = layout(list).filter(row => !finding || row.commit.hash === UNCOMMITTED || matches(row.commit, v.find))
    const lanes = Math.min(16, lanesOf(rows))

    const detail = (row: Row) => {
      const c = row.commit
      if (c.hash === UNCOMMITTED) {
        const tree: Target = { kind: 'changes' }
        return card(
          'detail',
          `Uncommitted changes (${r.changes.length})`,
          r.branch ? `on ${r.branch}` : 'on a detached HEAD',
          [
            <Box key="files" flexDirection="column" width="100%">
              {r.changes.slice(0, 30).map((ch, i) => (
                <Box key={`ch:${i}`} width="100%">
                  <Box width={4} flexShrink={0}><Text color={ch.code.includes('?') ? C.green : ch.code.includes('D') ? C.red : C.amber}>{ch.code}</Text></Box>
                  <Text color={C.subtle} wrap="truncate-start">{ch.path}</Text>
                </Box>
              ))}
              {r.changes.length > 30 ? <Text color={C.label}>{`${r.changes.length - 30} more`}</Text> : null}
            </Box>,
            groupRow('tree', 'Working tree', null, tree, actionsFor(tree, r)),
          ],
          tree,
        )
      }
      const here = shownRefs.filter(x => x.hash === c.hash)
      const commit: Target = { kind: 'commit', hash: c.hash }
      const all = actionsFor(commit, r)
      const refTargets = here.map((x): Target => ({ kind: x.kind, name: x.name }))
      const known = info?.hash === c.hash ? info : null
      // The message below its first line, which is the card's heading already.
      const rest = (known?.body ?? '').split('\n').slice(1).join('\n').trim()
      const message = rest ? (
        <Box key="message" width="100%">
          <Text color={C.soft} wrap="wrap">{rest.split('\n').slice(0, 14).join('\n')}</Text>
        </Box>
      ) : null
      const files = known ? (
        <Box key="changed" flexDirection="column" width="100%">
          {caption(known.against ? `Differs from ${known.against.slice(0, 7)} in ${known.files.length} ${known.files.length === 1 ? 'file' : 'files'}` : `${known.files.length} ${known.files.length === 1 ? 'file' : 'files'} changed`)}
          {known.files.slice(0, 40).map((f, i) => (
            <Box key={`f:${i}`} width="100%">
              <Box width={7} flexShrink={0}><Text color={C.green}>{f.added === null ? 'bin' : `+${f.added}`}</Text></Box>
              <Box width={7} flexShrink={0}><Text color={C.red}>{f.removed === null ? '' : `−${f.removed}`}</Text></Box>
              <Text color={C.subtle} wrap="truncate-start">{f.path}</Text>
            </Box>
          ))}
          {known.files.length > 40 ? <Text color={C.label}>{`${known.files.length - 40} more`}</Text> : null}
        </Box>
      ) : null
      // Comparing: mark one commit, then select another to see what differs between them.
      const comparing = (
        <Box key="g:compare" width="100%" alignItems="center">
          <Box width={LABEL_W} flexShrink={0}>{caption('Compare')}</Box>
          {marked === c.hash ? (
            <Box alignItems="center" flexWrap="wrap" flexShrink={1} minWidth={0} columnGap={GX} rowGap={GY}>
              <Box flexShrink={1} minWidth={0}><Text color={C.amber} wrap="wrap">marked: select another commit to compare it with this one</Text></Box>
              <Button key="compare-clear" variant="secondary" label="Clear mark" onPress={() => markToCompare(null)} />
            </Box>
          ) : (
            <Box alignItems="center" flexWrap="wrap" columnGap={GX} rowGap={GY}>
              <Button key="compare-mark" variant="secondary" label={marked ? 'Mark this one instead' : 'Mark to compare'} onPress={() => markToCompare(c.hash)} />
              {marked ? <Button key="compare-clear" variant="secondary" label="Stop comparing" onPress={() => markToCompare(null)} /> : null}
            </Box>
          )}
        </Box>
      )
      if (c.stash) {
        const stash: Target = { kind: 'stash', name: c.stash }
        return card('detail', c.subject, `${c.hash}  ·  ${new Date(c.at * 1000).toISOString().slice(0, 16).replace('T', ' ')} UTC`, [files, groupRow('stash', 'Stash', null, stash, actionsFor(stash, r))], stash)
      }
      return card(
        'detail',
        c.subject,
        `${c.hash}  ·  ${c.author}  ·  ${new Date(c.at * 1000).toISOString().slice(0, 16).replace('T', ' ')} UTC`,
        [
          message,
          files,
          groupRow('commit', 'Commit', null, commit, all.filter(a => a.group === 'commit')),
          groupRow('current', r.branch ?? 'HEAD', null, commit, all.filter(a => a.group === 'current')),
          groupRow('reset', `Reset ${r.branch ?? 'HEAD'}`, null, commit, all.filter(a => a.group === 'reset')),
          comparing,
          // A worktree checked out here: where its folder is and what it is on. Nothing is done to it from the graph.
          ...shownTrees.filter(w => w.head === c.hash).map(w => (
            <Box key={`g:wt:${w.path}`} width="100%" alignItems="flex-start">
              <Box width={LABEL_W} flexShrink={0}><Text color={C.purple} bold wrap="truncate">{treeLabel(w)}</Text></Box>
              <Box flexGrow={1} flexShrink={1} minWidth={0}>
                <Text color={C.subtle} wrap="wrap">{`worktree on ${w.branch ?? 'a detached HEAD'}${w.isLocked ? ', locked' : ''}${w.isPrunable ? ', its folder is gone' : ''}  ·  ${w.path}`}</Text>
              </Box>
            </Box>
          )),
          ...here.map((x, i) => groupRow(`ref:${x.kind}:${x.name}`, x.kind === 'tag' ? `◇ ${x.name}` : x.name, refColor(x.kind, x.name), refTargets[i] as Target, actionsFor(refTargets[i] as Target, r))),
        ],
        commit,
        refTargets,
      )
    }

    // The graph's column, in cells: wide enough for the drawing, the same for every row.
    const graphCells = finding ? 2 : Svg ? Math.ceil(cellWidth(lanes) / CELL_PX) + 1 : lanes * 2
    // The columns that fit the panel as wide as it is now: it is drawn again whenever it is resized.
    const body = e.props.bodyColumns ?? 100
    const cols = fitColumns(v.columns, body, graphCells)
    const headings = (
      <Box key="headings" width="100%" flexShrink={0}>
        <Box width={graphCells} flexShrink={0}><Text color={C.label}>{' '}</Text></Box>
        <Box flexGrow={1} flexShrink={1} minWidth={0} paddingLeft={GX}><Text color={C.label}>DESCRIPTION</Text></Box>
        {cols.author > 0 ? <Box width={cols.author} flexShrink={0} paddingLeft={GX}><Text color={C.label}>AUTHOR</Text></Box> : null}
        {cols.age > 0 ? <Box width={cols.age} flexShrink={0} paddingLeft={GX}><Text color={C.label}>AGE</Text></Box> : null}
        {cols.commit > 0 ? <Box width={cols.commit} flexShrink={0} paddingLeft={GX}><Text color={C.label}>COMMIT</Text></Box> : null}
      </Box>
    )
    const commitRow = (row: Row) => {
      const c = row.commit
      const isSel = sel === c.hash
      const isHead = c.hash === r.head
      const here = shownRefs.filter(x => x.hash === c.hash)
      const cell = Svg ? (
        <Svg source={cellSvg(row, lanes, { isHead, isSelected: isSel })} alt={c.hash === UNCOMMITTED ? 'working tree' : `commit ${c.hash.slice(0, 7)}`} width={cellWidth(lanes)} height={24} />
      ) : (
        <Text color={laneColor(row.color)}>{cellText(row, lanes)}</Text>
      )
      return (
        <Box key={`row:${c.hash}`} flexDirection="column" width="100%">
          <Box width="100%" alignItems="center">
            <Box width={graphCells} flexShrink={0}>{finding ? <Text color={laneColor(row.color)}>● </Text> : cell}</Box>
            {here.map(x => (
              <Box key={`ref:${x.kind}:${x.name}`} flexShrink={0} paddingLeft={GX}>
                <Text color={refColor(x.kind, x.name)} bold={x.kind === 'head' && x.name === r.branch}>{x.kind === 'tag' ? `◇ ${x.name}` : x.name}</Text>
              </Box>
            ))}
            {shownTrees.filter(w => w.head === c.hash).map(w => (
              <Box key={`wt:${w.path}`} flexShrink={0} paddingLeft={GX}>
                <Text color={C.purple}>{treeLabel(w)}</Text>
              </Box>
            ))}
            {isHead && !r.branch ? (
              <Box key="detached" flexShrink={0} paddingLeft={GX}>
                <Text color={C.green} bold>HEAD</Text>
              </Box>
            ) : null}
            <Box flexGrow={1} flexShrink={1} minWidth={0} paddingLeft={GX}>
              <Button
                key={`sel:${c.hash}`}
                plain
                dimColor={c.hash === UNCOMMITTED && !isSel}
                label={`${isSel ? '▸ ' : ''}${marked === c.hash ? '⇄ ' : ''}${c.subject}`}
                onPress={() => select(c.hash)}
              />
            </Box>
            {cols.author > 0 ? <Box width={cols.author} flexShrink={0} paddingLeft={GX}><Text color={C.subtle} wrap="truncate">{c.author}</Text></Box> : null}
            {cols.age > 0 ? <Box width={cols.age} flexShrink={0} paddingLeft={GX}><Text color={C.subtle} wrap="truncate">{c.hash === UNCOMMITTED ? '' : fmtAgo(now - c.at)}</Text></Box> : null}
            {cols.commit > 0 ? <Box width={cols.commit} flexShrink={0} paddingLeft={GX}><Text color={C.label}>{c.hash === UNCOMMITTED ? '' : c.hash.slice(0, 7)}</Text></Box> : null}
          </Box>
          {isSel ? detail(row) : null}
        </Box>
      )
    }

    const branchOptions = [
      { value: '', label: 'All branches' },
      ...r.refs.filter(x => x.kind === 'head' || (x.kind === 'remote' && v.showRemotes)).slice(0, BRANCHES_MAX).map(x => ({ value: x.name, label: x.name })),
    ]
    // A toolbar group: a caption over its controls.
    const group = (key: string, label: string, controls: RenderChildren, grows = false) => (
      <Box key={`tb:${key}`} flexDirection="column" flexShrink={grows ? 1 : 0} flexGrow={grows ? 1 : 0} minWidth={0}>
        {caption(label)}
        <Box alignItems="center" columnGap={GX}>{controls}</Box>
      </Box>
    )
    // On or off, said by a filled or hollow mark in the colour of what it shows.
    const onOff = (key: string, label: string, isOn: boolean, color: string, press: () => unknown) => (
      <Box key={`${key}-box`} alignItems="center" flexShrink={0}>
        <Text color={isOn ? color : C.label}>{isOn ? '● ' : '○ '}</Text>
        <Button key={key} plain dimColor={!isOn} label={label} onPress={press} />
      </Box>
    )
    const repoTarget: Target = { kind: 'repo' }
    // What the last action did: a card of its own colour, as wide as its words. It is pinned to
    // the bottom centre of the part of the panel that shows, so the graph scrolls behind it:
    // the panel says how many rows it shows and, where it scrolls as a whole, which row its
    // window starts at, and asks again whenever it is scrolled. Where it says neither, the
    // toast ends the panel instead.
    const shows = { offset: e.props.scroll?.offset ?? 0, bodyRows: e.props.scroll?.bodyRows ?? 0 }
    const isToastPinned = shows.bodyRows > PIN_ROWS
    const toastBox = note && look ? (
      <Box key="toast" borderStyle="round" borderColor={look.color} backgroundColor={C.card} paddingX={GX} paddingY={e.surface === 'terminal' ? 0 : GY} flexShrink={1} minWidth={0} alignItems="flex-start">
        <Box flexShrink={0} paddingRight={GX}><Text color={look.color} bold>{look.mark}</Text></Box>
        <Box flexDirection="column" flexShrink={1} minWidth={0}>
          <Text color={C.text} bold wrap="wrap">{note.title}</Text>
          {note.text ? <Text color={C.soft} wrap="wrap">{note.text}</Text> : null}
        </Box>
        <Box flexShrink={0} paddingLeft={GX}><Button key="toast-dismiss" plain dimColor label="dismiss" onPress={() => dismiss($)} /></Box>
      </Box>
    ) : null
    const toolbar = (
        <Box width="100%" flexWrap="wrap" alignItems="flex-start" columnGap={GX * 2} rowGap={GY}>
          {Select
            ? group('branches', 'Branches', <Select key="branch" options={branchOptions} value={branchOptions.some(o => o.value === v.branch) ? v.branch : ''} onSelect={value => setView({ branch: value })} />)
            : null}
          {group('show', 'Show', [
            onOff('remotes', 'remotes', v.showRemotes, C.cyan, () => setView({ showRemotes: !v.showRemotes })),
            onOff('tags', 'tags', v.showTags, C.amber, () => setView({ showTags: !v.showTags })),
            // Offered only where the repository has another worktree.
            (r.worktrees ?? []).length > 0 ? onOff('worktrees', 'worktrees', v.showWorktrees ?? true, C.purple, () => setView({ showWorktrees: !(v.showWorktrees ?? true) })) : null,
          ])}
          {group('remote', 'Remote', [
            // Push and Pull say how many commits each would move: only the button's words change, not the action.
            ...actionsFor(repoTarget, r).map((a, i) => {
              const count = a.id === 'push' ? (r.ahead ?? 0) : a.id === 'pull' ? (r.behind ?? 0) : 0
              return actionButton(repoTarget, count > 0 ? { ...a, label: `${a.label} ${a.id === 'push' ? '↑' : '↓'}${count}` } : a, i === 0)
            }),
            <Button key="refresh" variant="secondary" label="Refresh" onPress={() => load($)} />,
          ])}
          {group(
            'columns',
            'Columns',
            <Button
              key="columns"
              variant="secondary"
              label={v.columns === 'compact' ? 'Compact' : v.columns === 'wide' ? 'Wide' : 'Normal'}
              onPress={async () => {
                const next = nextColumns(v.columns)
                await update($, view, old => ({ ...(old ?? VIEW), columns: next }))
                await $.store.set(COLUMNS_KEY, next).catch(() => undefined)
              }}
            />,
          )}
          {Input
            ? group('find', 'Find', [
                <Input key="find" placeholder="message, author or hash" value={v.find} submitLabel="find" onSubmit={value => update($, view, old => ({ ...(old ?? VIEW), find: value, from: 0, into: 0 }))} />,
                finding ? <Button key="find-clear" plain dimColor label="clear" onPress={() => update($, view, old => ({ ...(old ?? VIEW), find: '', from: 0, into: 0 }))} /> : null,
              ], true)
            : null}
        </Box>
    )
    const operation = r.operation ? (
          <Box key="operation" flexDirection="column" width="100%" rowGap={GY}>
            <Text color={C.amber} bold wrap="wrap">{`A ${r.operation} is in progress. Resolve the conflicts in the files, then continue it; or abort it to go back to where it started.`}</Text>
            <Box alignItems="center" flexWrap="wrap" columnGap={GX} rowGap={GY}>{actionsFor({ kind: 'operation' }, r).map((a, i) => actionButton({ kind: 'operation' }, a, i === 0))}</Box>
            {ask({ kind: 'operation' })}
          </Box>
        ) : null
    // The panel holds only so much (see TREE_BUDGET), so the list draws only the rows from the
    // top of its own window: enough lines to fill the window, and no more than the rest of the
    // panel leaves room for. A row is measured as it is drawn, so fewer are drawn where many
    // lines run side by side or a row is unfolded.
    const budget = Math.max(ROWS_BUDGET_MIN, TREE_BUDGET - sizeOf([toolbar, ask({ kind: 'repo' }), operation, headings, toastBox]))
    const drawn = new Map<number, RenderChildren>()
    const rowAt = (i: number) => {
      if (!drawn.has(i)) drawn.set(i, commitRow(rows[i] as Row))
      return drawn.get(i) as RenderChildren
    }
    const cost = (i: number) => sizeOf(rowAt(i))
    // A row is one line, the selected one as many as it and its card take, so a scroll goes
    // through a tall card a line at a time instead of past it.
    const selAt = rows.findIndex(row => row.commit.hash === sel)
    const selRows = selAt >= 0 ? Math.max(1, rowsOf(rowAt(selAt), body)) : 1
    const heightOf = (i: number) => (i === selAt ? selRows : 1)
    const isPinned = PINNED_LIST && shows.bodyRows >= PIN_MIN
    // The last rows do not scroll up out of sight: half a window of them stays.
    const last = Math.max(0, rows.length - Math.max(1, Math.floor(shows.bodyRows / 2)))
    // Past the end, as after a find that matches fewer: as far down as the list goes.
    const from = isPinned ? Math.min(Math.max(0, v.from ?? 0), last) : (v.from ?? 0) < rows.length ? Math.max(0, v.from ?? 0) : pageStart(budget, rows.length, cost)
    const into = Math.max(0, Math.min(v.into ?? 0, heightOf(from) - 1))
    let end = pageEnd(budget, from, rows.length, cost)
    if (isPinned && shows.bodyRows > 0) {
      let lines = -into
      let i = from
      while (i < end && lines < shows.bodyRows) lines += heightOf(i++)
      end = i
    }
    shape = { count: rows.length, selAt, selRows, last, from, into, offset: shows.offset, isPinned }
    // Under the last row read: that scrolling on reads more, or that this is the first commit.
    // More are read by a scroll near the end, not by drawing it: a find that matches few would
    // otherwise read the whole history at once.
    // Where the panel scrolls as a whole: a page of commits, with the next and the last a press away.
    const moveTo = async (change: Partial<View>, edge: 'start' | 'end') => {
      if (change.limit === undefined) await update($, view, old => ({ ...(old ?? VIEW), into: 0, ...change }))
      else await setView(change)
      await $.ui.scroll({ in: PANE, to: edge }).catch(() => undefined)
    }
    const older = () => moveTo(end < rows.length ? { from: end } : { limit: v.limit + PAGE, from: end }, 'start')
    const newer = () => moveTo({ from: pageStart(budget, from, cost) }, 'end')
    const isPaged = from > 0 || end < rows.length
    const paging = isPinned || !(end < rows.length || r.hasMore || isPaged) ? null : (
      <Box key="paging" width="100%" alignItems="center" columnGap={GX}>
        {end < rows.length || r.hasMore ? <Button key="more" plain dimColor label="↓ older commits" onPress={older} /> : null}
        {isPaged ? <Text color={C.label}>{`${from + 1}–${end} of ${rows.length}${r.hasMore ? '+' : ''}`}</Text> : null}
      </Box>
    )
    const foot = !isPinned || end < rows.length ? null : r.hasMore
      ? <Text key="foot" color={C.label}>scroll for older commits</Text>
      : from > 0 ? <Text key="foot" color={C.label}>the oldest commit</Text> : null
    // What stays at the top while the list scrolls: none of it gives up rows to the list.
    const fixed = (key: string, child: RenderChildren) => (child ? <Box key={key} flexDirection="column" width="100%" flexShrink={0}>{child}</Box> : null)
    const shift = Math.max(0, Math.min(SCROLL_SLACK, shows.offset))
    const panel = (
      <Box flexDirection="column" width="100%" rowGap={GY} position="relative" height={isPinned ? shows.bodyRows : undefined} marginTop={isPinned && shift > 0 ? shift : undefined} flexShrink={isPinned ? 0 : undefined} minHeight={!isPinned && isToastPinned ? shows.bodyRows : undefined} overflow={isPinned ? 'hidden' : undefined}>
        {fixed('top', toolbar)}
        {fixed('confirm', ask({ kind: 'repo' }))}
        {fixed('operation-bar', operation)}
        {rows.length === 0 ? <Text color={C.label}>{finding ? 'No commit matches.' : 'No commits yet.'}</Text> : null}
        {rows.length > 0 ? (
          <Box key="table" flexDirection="column" width="100%" flexGrow={1} flexShrink={1} minHeight={0}>
            {!isPinned && from > 0 ? <Button key="newer" plain dimColor label="↑ newer commits" onPress={newer} /> : null}
            {headings}
            {/* The list's window: the rows are drawn from its top row, the lines of that row
                already scrolled past held above it and cut off. */}
            <Box key="window" flexDirection="column" width="100%" flexGrow={1} flexShrink={1} minHeight={0} overflow={isPinned ? 'hidden' : undefined}>
              <Box key="rows" flexDirection="column" width="100%" flexShrink={0} marginTop={into > 0 ? -into : undefined}>
                {rows.slice(from, end).map((_row, i) => rowAt(from + i))}
                {foot}
              </Box>
            </Box>
          </Box>
        ) : null}
        {paging}
        {toastBox ? (isToastPinned ? (
          <Box key="toast-pin" position="absolute" top={Math.max(0, (isPinned ? 0 : shows.offset) + shows.bodyRows - PIN_ROWS)} left={0} width="100%" height={PIN_ROWS} flexDirection="column" justifyContent="flex-end" alignItems="center" paddingBottom={GY}>
            {toastBox}
          </Box>
        ) : (
          <Box key="toast-row" width="100%" justifyContent="center">{toastBox}</Box>
        )) : null}
      </Box>
    )
    // The rows under the window that keep the app handing the panel its wheel.
    return isPinned ? <Box flexDirection="column" width="100%" height={shows.bodyRows + SCROLL_SLACK} flexShrink={0}>{panel}</Box> : panel
  })
}
