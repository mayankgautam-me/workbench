import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, SessionCost, SessionContextUsage, SessionRateLimit, Timer } from 'claude-code'

import type { Agent, Limit, Task, Turn, Usage } from '../types'
import { describeCall, endedTasks, redact, fmtSeconds, fmtTokens, fmtUntil, fmtUsd, levelOf, limitLabel, plural, shorten } from './core'

const EMPTY: Usage = { pct: null, tokens: null, window: null, usd: null, limits: [] }
const EDIT_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit'])

// Tokyo Night. Each gauge has its own accent; any gauge turns amber from 70% and red from 90%.
const C = {
  label: '#565f89',
  subtle: '#737aa2',
  text: '#c0caf5',
  track: '#3b4261',
  rule: '#414868',
  blue: '#7aa2f7',
  purple: '#bb9af7',
  cyan: '#7dcfff',
  green: '#9ece6a',
  amber: '#e0af68',
  red: '#f7768e',
}
const ACCENTS: Record<string, string> = { five_hour: C.purple, seven_day: C.cyan }
const MAX_AGENTS_SHOWN = 4
const MAX_TASKS_SHOWN = 4
const gaugeColor = (pct: number, accent: string) => ({ ok: accent, warn: C.amber, high: C.red })[levelOf(pct)]

const usage = atom({ plugin: 'status-band', key: 'usage' } as const, EMPTY)
const last = atom({ plugin: 'status-band', key: 'last' } as const, null)
const agents = atom({ plugin: 'status-band', key: 'agents' } as const, [])
const tasks = atom({ plugin: 'status-band', key: 'tasks' } as const, [])
const isHidden = atom({ plugin: 'status-band', key: 'isHidden' } as const, false)
const isCompact = atom({ plugin: 'status-band', key: 'isCompact' } as const, false)
// The session-tint mod's colour for this session; never set where that mod is not installed.
const sessionTint = atom({ plugin: 'session-tint', key: 'tint' } as const, null)
// True where a session-tint new enough to put the map's toggle on its rule is loaded.
const tintCarriesMap = atom({ plugin: 'session-tint', key: 'carriesMap' } as const, false)
// Whether the band is the one-line view is the person's choice, kept between sessions.
const COMPACT_KEY = 'compact'
// Whether the agent-map mod's panel is shown; never set where that mod is not installed.
const mapIsOpen = atom({ plugin: 'agent-map', key: 'isOpen' } as const, null)
// Tells the agent-map mod that this band draws the map's toggle, so it adds no row of its own.
const carriesMap = atom({ plugin: 'status-band', key: 'carriesMap' } as const, false)
// Counts presses of the map toggle drawn here. The agent-map mod watches it and shows or hides
// its panel; running its /map command instead would print the command into the transcript.
const mapPress = atom({ plugin: 'status-band', key: 'mapPress' } as const, 0)
// The same three for the git-graph mod's panel: whether it is shown (never set where that mod
// is not installed or the session is not in a repository), that this band draws its toggle, and
// the presses of it.
const graphIsOpen = atom({ plugin: 'git-graph', key: 'isOpen' } as const, null)
const carriesGraph = atom({ plugin: 'status-band', key: 'carriesGraph' } as const, false)
const graphPress = atom({ plugin: 'status-band', key: 'graphPress' } as const, 0)
const tintCarriesGraph = atom({ plugin: 'session-tint', key: 'carriesGraph' } as const, false)

const toUsage = (context: SessionContextUsage, rateLimits: SessionRateLimit[], cost: SessionCost | undefined): Usage => ({
  pct: context.percent ?? null,
  tokens: context.tokens ?? null,
  window: context.window,
  usd: cost?.usd ?? null,
  limits: rateLimits.map(r => ({ kind: r.kind, pct: r.percentUsed, resetsAt: r.resetsAt ?? null })),
})

// The plan limits are the account's, not the session's: the last reading is kept between
// sessions so a new one opens with it. A window whose reset has passed starts again at zero.
const LIMITS_KEY = 'limits'
const savedLimits = async ($: EngineInterface, now: number): Promise<Limit[]> => {
  const kept = await $.store.get(LIMITS_KEY)
  if (!Array.isArray(kept)) return []
  return (kept as Limit[])
    .filter(l => typeof l?.kind === 'string' && typeof l.pct === 'number')
    .map(l => (l.resetsAt && Date.parse(l.resetsAt) <= now ? { kind: l.kind, pct: 0, resetsAt: null } : l))
}

// Before the first reply the engine has no context reading: fill it with the local estimate
// /context makes, which sends nothing. A real reading that arrives first is kept.
const estimateContext = async ($: EngineInterface) => {
  const b = (await $.session.usage({ breakdown: 'summary' })).context.breakdown
  if (!b) return
  await update($, usage, cur => {
    const u = cur ?? EMPTY
    return u.pct !== null ? u : { ...u, pct: b.percentage, tokens: b.totalTokens, window: b.rawMaxTokens, isEstimated: true }
  })
}

// A reading without a figure (no limits read, a window just compacted) keeps the last one.
// Nothing is written when nothing moved, so a poll that finds the same figures draws nothing.
const applyUsage = async ($: EngineInterface, measured: Usage) => {
  const u = (await read($, usage)) ?? EMPTY
  const merged: Usage = {
    ...measured,
    ...(measured.pct === null ? { pct: u.pct, tokens: u.tokens, isEstimated: u.isEstimated } : {}),
    limits: measured.limits.length > 0 ? measured.limits : u.limits,
  }
  if (JSON.stringify(merged) === JSON.stringify(u)) return
  await update($, usage, () => merged)
  if (measured.limits.length > 0 && JSON.stringify(measured.limits) !== JSON.stringify(u.limits))
    await $.store.set(LIMITS_KEY, measured.limits).catch(() => undefined)
}
// The engine measures when a turn ends; in between, the band reads the same figures itself
// (the plain call costs nothing), so context, limits and cost move while a turn runs.
const pollUsage = async ($: EngineInterface) => {
  const u = await $.session.usage()
  await applyUsage($, toUsage(u.context, u.rateLimits, u.cost))
}

const getAgents = async ($: EngineInterface): Promise<Agent[]> => (await read($, agents)) ?? []
const patchAgent = ($: EngineInterface, id: string, change: (a: Agent) => Agent) =>
  update($, agents, list => (list ?? []).map(a => (a.id === id ? change(a) : a)))

// The engine's own list of this session's subagents, so ones that were already running when
// the band loaded (or that run in the background across turns) are shown and kept in step.
type Listed = { id: string; description?: string; type?: string; name?: string; status: string }
const STATUS_OF: Record<string, Agent['status']> = { completed: 'done', failed: 'failed', killed: 'failed' }
const syncAgents = async ($: EngineInterface) => {
  const listed = (await ($.agent.list() as unknown as Promise<Listed[]>).catch(() => null)) ?? null
  if (!listed) return
  const now = await $.clock.now()
  await update($, agents, list => {
    const known = list ?? []
    const merged = known.map(a => {
      const l = listed.find(x => x.id === a.id)
      if (!l) return a
      const status = STATUS_OF[l.status] ?? 'running'
      return status === a.status ? a : { ...a, status, tool: status === 'running' ? a.tool : null, endedAt: status === 'running' ? null : (a.endedAt ?? now) }
    })
    const fresh = listed
      .filter(l => !known.some(a => a.id === l.id) && (STATUS_OF[l.status] ?? 'running') === 'running')
      .map<Agent>(l => ({
        id: l.id,
        name: shorten(l.name ?? l.description ?? l.type ?? 'agent', 40),
        status: 'running',
        tool: null,
        tools: 0,
        startedAt: null,
        endedAt: null,
      }))
    return [...merged, ...fresh].slice(-12)
  })
}

// Background work the session reports when a turn ends: shell commands, monitors, workflows.
// Subagents are left to the agents table.
type Reported = { id: string; type: string; status: string; description: string; command?: string }
const syncTasks = async ($: EngineInterface, reported: Reported[]) => {
  const now = await $.clock.now()
  const live = reported.filter(t => t.type !== 'subagent')
  await update($, tasks, list => {
    const known = list ?? []
    // One we were tracking that is no longer reported has finished.
    const kept = known.map(t =>
      t.status === 'running' && !live.some(l => l.id === t.id) ? { ...t, status: 'done' as const, endedAt: now } : t,
    )
    const fresh = live
      .filter(l => !known.some(t => t.id === l.id))
      .map<Task>(l => ({
        id: l.id,
        kind: l.type,
        label: shorten(redact((l.command || l.description || l.type).replace(/\s+/g, ' ').trim()), 60),
        status: 'running',
        startedAt: null,
        endedAt: null,
      }))
    return [...kept, ...fresh].slice(-12)
  })
}

// A notification names what ended: a background task, or a background subagent by its id.
const markEnded = async ($: EngineInterface, ended: { id: string; isFailed: boolean }[]) => {
  if (ended.length === 0) return
  const now = await $.clock.now()
  const statusOf = (id: string) => (ended.find(x => x.id === id)?.isFailed ? ('failed' as const) : ('done' as const))
  await update($, tasks, list =>
    (list ?? []).map(t => (t.status === 'running' && ended.some(x => x.id === t.id) ? { ...t, status: statusOf(t.id), endedAt: now } : t)),
  )
  await update($, agents, list =>
    (list ?? []).map(a =>
      a.status === 'running' && ended.some(x => x.id === a.id) ? { ...a, status: statusOf(a.id), tool: null, endedAt: now } : a,
    ),
  )
}

const TICK_MS = 1000
const LINGER_MS = 20_000
const AGENT_POLL_TICKS = 3
const USAGE_POLL_TICKS = 2

export const register: Register = on => {
  let startedAt = 0
  let tools = 0
  let edits = 0
  // Whether the last drawing showed anything still running: the ticker redraws only then.
  let isBusy = false
  let ticks = 0
  let ticker: Timer | null = null

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'band', description: 'Show or hide the status band above the message box' })
    await update($, carriesMap, () => true)
    await update($, carriesGraph, () => true)
    // A host without usage figures (headless, not yet bound) just starts empty.
    const u = await $.session.usage().catch(() => null)
    let opened = u ? toUsage(u.context, u.rateLimits, u.cost) : EMPTY
    if (opened.limits.length === 0) {
      const now = await $.clock.now().catch(() => Date.now())
      opened = { ...opened, limits: await savedLimits($, now).catch(() => []) }
    }
    await update($, usage, () => opened)
    // Not awaited: the estimate must not hold up the session's start.
    if (opened.pct === null) void estimateContext($).catch(() => undefined)
    const compact = (await $.store.get(COMPACT_KEY).catch(() => false)) === true
    await update($, isCompact, () => compact)
    await syncAgents($).catch(() => undefined)
    // Every two seconds, read the usage figures again. While something runs, also redraw every
    // second so its timer counts up, and re-read the session's agent list every few seconds
    // so a finished one is marked without a reply.
    try {
      ticker?.cancel()
      ticker = $.clock.every(TICK_MS, () => {
        ticks += 1
        if (ticks % USAGE_POLL_TICKS === 0) void pollUsage($).catch(() => undefined)
        if (!isBusy) return
        if (ticks % AGENT_POLL_TICKS === 0) void syncAgents($).catch(() => undefined)
        $.ui.invalidate('ui.render')
      })
    } catch {
      // A host without timers: the band still updates on every event it sees.
    }
    return next(e)
  })

  // A background task's notification opens a turn when the session is idle: mark it finished
  // the moment that turn starts, not when the reply to it ends.
  on('turn.start', async ($, e, next) => {
    await markEnded($, endedTasks(e.text ?? '')).catch(() => undefined)
    return next(e)
  })

  // Delivered into a turn already running, the notification is a row of the transcript.
  on('session.append', async ($, e, next) => {
    const message = (e as unknown as { message?: { type?: string; content?: unknown } }).message
    if (message?.type === 'user') {
      const content = message.content
      const text =
        typeof content === 'string'
          ? content
          : Array.isArray(content)
            ? content.map(b => (typeof (b as { text?: unknown }).text === 'string' ? (b as { text: string }).text : '')).join('\n')
            : ''
      if (text.includes('<task-id>')) await markEnded($, endedTasks(text.slice(0, 20_000))).catch(() => undefined)
    }
    return next(e)
  })

  // A turn's end is when the session says what is still running in the background.
  on('classic.Stop', async ($, e, next) => {
    const reported = (e as unknown as { background_tasks?: Reported[] }).background_tasks
    if (reported) await syncTasks($, reported).catch(() => undefined)
    await syncAgents($).catch(() => undefined)
    return next(e)
  })

  on('command.run', { command: 'band' }, async $ => {
    const hidden = !(await read($, isHidden))
    await update($, isHidden, () => hidden)
    return { text: hidden ? 'Status band hidden. /band shows it again.' : 'Status band shown.' }
  })

  on('session.measure', async ($, e, next) => {
    await applyUsage($, toUsage(e.context, e.rateLimits, e.cost))
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    // A failed clock read must never hold up the prompt.
    startedAt = await $.clock.now().catch(() => 0)
    tools = 0
    edits = 0
    // A new prompt clears the finished subagents; ones still running stay.
    await update($, agents, list => (list ?? []).filter(a => a.status === 'running')).catch(() => undefined)
    await update($, tasks, list => (list ?? []).filter(t => t.status === 'running')).catch(() => undefined)
    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    const started = await next(e)
    if (started.deny !== undefined || !started.agentId) return started
    const agent: Agent = {
      id: started.agentId,
      name: shorten(e.name ?? e.description ?? e.subagentType, 22),
      status: 'running',
      tool: null,
      tools: 0,
      startedAt: await $.clock.now(),
      endedAt: null,
    }
    await update($, agents, list => [...(list ?? []).filter(a => a.id !== agent.id), agent].slice(-12))
    return started
  })

  on('tool.call', async ($, e, next) => {
    const id = e.agentId
    if (id) {
      const doing = describeCall(String(e.tool), e as unknown as Record<string, unknown>)
      await patchAgent($, id, a => ({ ...a, tool: doing }))
    }
    const ran = await next(e)
    if (id) {
      await patchAgent($, id, a => ({ ...a, tool: null, tools: a.tools + 1 }))
    } else {
      tools += 1
      if (ran.deny === undefined && ran.isError !== true && EDIT_TOOLS.has(e.tool)) edits += 1
    }
    const args = e as unknown as { run_in_background?: boolean }
    const taskId = (ran as unknown as { result?: { backgroundTaskId?: string } }).result?.backgroundTaskId
    if (ran.deny === undefined && taskId && (args.run_in_background || String(e.tool) === 'Bash')) {
      const now = await $.clock.now()
      const task: Task = {
        id: taskId,
        kind: 'shell',
        label: describeCall(String(e.tool), e as unknown as Record<string, unknown>, 60),
        status: 'running',
        startedAt: now,
        endedAt: null,
      }
      await update($, tasks, list => [...(list ?? []).filter(t => t.id !== task.id), task].slice(-12))
    }
    return ran
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    const now = await $.clock.now()
    if (e.agentId) {
      const status = e.reason === 'answer' ? 'done' : 'failed'
      await patchAgent($, e.agentId, a => ({ ...a, status, tool: null, endedAt: now }))
    } else if (startedAt > 0) {
      const turn: Turn = { seconds: Math.round((now - startedAt) / 1000), tools, edits }
      await update($, last, () => turn)
    }
    return done
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey || (await read($, isHidden))) return next(e)

    const u = (await read($, usage)) ?? EMPTY
    const turn = await read($, last)
    const now = await $.clock.now()
    // A finished agent or task stays for a short while, then leaves the band by itself: an idle
    // session is not left showing work that ended long ago.
    const isFresh = (x: { status: string; endedAt: number | null }) =>
      x.status === 'running' || (x.endedAt !== null && now - x.endedAt < LINGER_MS)
    const team = (await getAgents($)).filter(isFresh)
    const jobs: Task[] = ((await read($, tasks)) ?? []).filter(isFresh)
    const { Box, Button, Text } = $.ui.resolve(e)
    // Whatever another mod draws in the band (a session's colour rule) goes on top of this one.
    // The engine's own answer draws nothing here and cannot sit inside a tree, so it is left out.
    const beneath = await next(e)
    const below = beneath.type === 'engine' ? null : beneath
    const compact = (await read($, isCompact)) === true
    // One glyph, no frame: ▸ opens the full band, ▾ folds it to one line.
    const toggle = (
      <Button
        key="compact"
        plain
        label={compact ? '▸' : '▾'}
        onPress={async () => {
          await update($, isCompact, () => !compact)
          await $.store.set(COMPACT_KEY, !compact).catch(() => undefined)
        }}
      />
    )

    // With the agent-map mod installed, the band shows or hides the project map. Folded: an
    // icon before the A and T counts, filled while the panel is shown. Unfolded: the word
    // `map` at the left end of the session's coloured rule, which session-tint draws; only
    // where there is no such rule does the word sit here, at the left of the gauges.
    const mapOpen = await read($, mapIsOpen).catch(() => null)
    const hasMap = mapOpen === true || mapOpen === false
    const runMap = async () => {
      await update($, mapPress, n => (n ?? 0) + 1).catch(() => undefined)
    }
    const mapIcon = hasMap ? (
      <Box key="map" paddingRight={2} flexShrink={0}>
        <Button key="map-toggle" plain label={mapOpen ? '■' : '□'} onPress={runMap} />
      </Box>
    ) : null
    const ruleHasMap =
      (await read($, tintCarriesMap).catch(() => false)) === true && (await read($, sessionTint).catch(() => null)) !== null
    const mapWord =
      hasMap && !ruleHasMap ? (
        <Box key="map" paddingRight={2} flexShrink={0}>
          <Button key="map-toggle" plain label="map" onPress={runMap} />
        </Box>
      ) : null
    // The git graph's toggle, by the same rules as the map's but at the other end of the row,
    // the right: an icon when folded, the word `graph` at the right end of the session's rule
    // when unfolded, or at the right of the gauges where there is no such rule.
    const graphOpen = await read($, graphIsOpen).catch(() => null)
    const hasGraph = graphOpen === true || graphOpen === false
    const runGraph = async () => {
      await update($, graphPress, n => (n ?? 0) + 1).catch(() => undefined)
    }
    const graphIcon = hasGraph ? (
      <Box key="graph" paddingRight={2} flexShrink={0}>
        <Button key="graph-toggle" plain label={graphOpen ? '◆' : '◇'} onPress={runGraph} />
      </Box>
    ) : null
    const ruleHasGraph =
      (await read($, tintCarriesGraph).catch(() => false)) === true && (await read($, sessionTint).catch(() => null)) !== null
    const graphWord =
      hasGraph && !ruleHasGraph ? (
        <Box key="graph" paddingRight={2} flexShrink={0}>
          <Button key="graph-toggle" plain label="graph" onPress={runGraph} />
        </Box>
      ) : null

    // Four equal columns across the band's full width. Everything is sized by the layout
    // (percent widths and flex), never by counting characters, so nothing can spill into
    // the next column whatever font the surface draws with.
    // The band follows its width, which the surface reports in cells and reports again when the
    // window is resized. Wide: four columns with a line of detail under each bar. Medium: the
    // same with shorter detail. Narrow: two rows of two, short labels, no detail.
    const cells = e.props.bodyColumns || 120
    const tier: 'wide' | 'mid' | 'narrow' = cells >= 110 ? 'wide' : cells >= 72 ? 'mid' : 'narrow'
    const SHORT: Record<string, string> = { context: 'Ctx', five_hour: '5h', seven_day: 'Week', session: 'Cost' }
    // One gap for the whole band, the same as the git graph's and the map's: two cells across
    // match one row down, so GUTTER stands between things side by side and ROW between things
    // stacked, also where a row wraps.
    const GUTTER = 2
    const ROW = 1
    const colWidth = tier === 'narrow' ? '50%' : '25%'

    const detail = (text: string, color: string = C.subtle) => (
      <Text color={color} wrap="truncate">
        {text}
      </Text>
    )
    // A thin bar: the used part takes `pct` of the column, the dark track the rest.
    // The desktop app draws it as a 4px vector line stretched to the column's width (inside a
    // 10px strip, for a little air above and below). The terminal has no vector element, so
    // there it is a one-row block sized by the layout.
    const Svg = e.surface === 'terminal' ? undefined : $.ui.resolve(e).Svg
    const bar = (pct: number | null, accent: string) => {
      const used = pct === null ? 0 : Math.max(0, Math.min(100, pct))
      const color = gaugeColor(used, accent)
      if (Svg) {
        const source =
          `<svg xmlns="http://www.w3.org/2000/svg" width="2000" height="10" viewBox="0 0 100 10" preserveAspectRatio="none">` +
          `<rect x="0" y="3" width="100" height="4" fill="${C.track}"/>` +
          (used > 0 ? `<rect x="0" y="3" width="${used}" height="4" fill="${color}"/>` : '') +
          `</svg>`
        return (
          <Box width="100%">
            <Svg source={source} alt={pct === null ? 'no reading yet' : `${Math.round(used)}% used`} height={10} />
          </Box>
        )
      }
      return (
        <Box width="100%" height={1}>
          {used > 0 ? <Box flexGrow={used} height={1} backgroundColor={color} /> : null}
          {used < 100 ? <Box flexGrow={100 - used} height={1} backgroundColor={C.track} /> : null}
        </Box>
      )
    }
    // The session's bar measures nothing, so it carries no fill: diagonal stripes in the cost's
    // colour over the same track, the same height as the gauges beside it.
    const stripedBar = (color: string | null) => {
      if (Svg) {
        // Drawn in a 100-wide box that the surface stretches sideways, so the lean is slight here.
        const PERIOD = 2.4, WIDTH = 1.2, LEAN = 1.3
        let stripes = ''
        if (color) {
          for (let x = -PERIOD; x < 100; x += PERIOD) {
            const a = x.toFixed(2), b = (x + WIDTH).toFixed(2), c = (x + WIDTH + LEAN).toFixed(2), d = (x + LEAN).toFixed(2)
            stripes += `<polygon points="${a},7 ${b},7 ${c},3 ${d},3" fill="${color}"/>`
          }
        }
        const source =
          `<svg xmlns="http://www.w3.org/2000/svg" width="2000" height="10" viewBox="0 0 100 10" preserveAspectRatio="none">` +
          `<rect x="0" y="3" width="100" height="4" fill="${C.track}"/>${stripes}</svg>`
        return (
          <Box width="100%">
            <Svg source={source} alt="session" height={10} />
          </Box>
        )
      }
      return (
        <Box width="100%" height={1}>
          {Array.from({ length: 24 }, (_, i) => (
            <Box key={`stripe-${i}`} flexGrow={1} height={1} backgroundColor={color && i % 2 === 0 ? color : C.track} />
          ))}
        </Box>
      )
    }
    // HEADING ........ 42%
    const head = (title: string, value: string, color: string) => (
      <Box width="100%" justifyContent="space-between">
        <Text color={C.label} bold wrap="truncate">
          {title.toUpperCase()}
        </Text>
        <Text color={color} bold>
          {value}
        </Text>
      </Box>
    )
    const column = (key: string, top: JSX.Element, middle: JSX.Element, bottom: JSX.Element) => (
      <Box key={key} flexDirection="column" width={colWidth} paddingRight={GUTTER}>
        {top}
        {middle}
        {tier === 'narrow' ? null : bottom}
      </Box>
    )
    const titleOf = (key: string, title: string) => (tier === 'narrow' ? (SHORT[key] ?? title) : title)
    const gaugeColumn = (key: string, title: string, pct: number | null, accent: string, note: string) =>
      column(
        key,
        head(titleOf(key, title), pct === null ? '—' : `${Math.round(pct)}%`, pct === null ? C.label : gaugeColor(pct, accent)),
        bar(pct, accent),
        detail(note, pct === null ? C.label : C.subtle),
      )

    // The two plan limits always have a column, so the layout does not jump when figures arrive.
    const limit = (kind: string) => u.limits.find(l => l.kind === kind) ?? null
    const limitColumn = (kind: string) => {
      const l = limit(kind)
      if (!l) return gaugeColumn(kind, limitLabel(kind), null, C.cyan, tier === 'wide' ? 'after the next reply' : 'no reading')
      const left = l.resetsAt ? fmtUntil(Date.parse(l.resetsAt) - now) : ''
      return gaugeColumn(kind, limitLabel(kind), l.pct, ACCENTS[kind] ?? C.cyan, left ? (tier === 'wide' ? `resets in ${left}` : `in ${left}`) : tier === 'wide' ? 'reset time unknown' : '')
    }
    const lastTurn = turn
      ? tier === 'wide'
        ? `last turn ${fmtSeconds(turn.seconds)} · ${plural(turn.tools, 'tool')} · ${plural(turn.edits, 'edit')}`
        : `${fmtSeconds(turn.seconds)} · ${plural(turn.tools, 'tool')}`
      : tier === 'wide' ? 'no turn finished yet' : ''

    // ● name   running [ sleep 8; date +%T ]   12s   3 tools
    const running = team.filter(a => a.status === 'running').length
    const finished = team.filter(a => a.status === 'done').length
    const failed = team.length - running - finished
    const shown = team.slice(-Math.max(1, Math.min(MAX_AGENTS_SHOWN, (e.props.maxRows || 10) - 5)))
    const agentRow = (a: Agent) => {
      const seconds = a.startedAt === null ? null : Math.max(0, Math.round(((a.endedAt ?? now) - a.startedAt) / 1000))
      const mark = a.status === 'running' ? '●' : a.status === 'done' ? '✓' : '✗'
      const color = a.status === 'running' ? C.blue : a.status === 'done' ? C.green : C.red
      return (
        <Box key={a.id} width="100%">
          <Box width={tier === 'narrow' ? '40%' : '25%'} paddingRight={GUTTER}>
            <Text color={color}>{`${mark} `}</Text>
            <Text color={a.status === 'running' ? C.text : C.subtle} wrap="truncate">
              {shorten(a.name, 40)}
            </Text>
          </Box>
          <Box width={tier === 'narrow' ? '45%' : '40%'} paddingRight={GUTTER}>
            {a.status !== 'running' ? (
              <Text color={color}>{a.status === 'done' ? 'done' : 'failed or stopped'}</Text>
            ) : a.tool ? (
              <Box>
                <Text color={C.subtle}>{'running '}</Text>
                <Text color={C.label}>{'[ '}</Text>
                <Text color={C.cyan} wrap="truncate">{a.tool}</Text>
                <Text color={C.label}>{' ]'}</Text>
              </Box>
            ) : (
              <Text color={C.subtle}>thinking</Text>
            )}
          </Box>
          <Box width="15%" paddingRight={GUTTER}>
            <Text color={seconds === null ? C.label : C.text}>{seconds === null ? '—' : fmtSeconds(seconds)}</Text>
          </Box>
          {tier === 'narrow' ? null : (
            <Box width="20%">
              <Text color={C.label}>{plural(a.tools, 'tool')}</Text>
            </Box>
          )}
        </Box>
      )
    }

    // ● shell   running [ npm run dev ]   2m05s
    const jobsRunning = jobs.filter(t => t.status === 'running').length
    // Keep redrawing while anything runs, and while a finished one is still waiting to leave.
    isBusy = team.length > 0 || jobs.length > 0
    const taskRow = (t: Task) => {
      const seconds = t.startedAt === null ? null : Math.max(0, Math.round(((t.endedAt ?? now) - t.startedAt) / 1000))
      const mark = t.status === 'running' ? '●' : t.status === 'done' ? '✓' : '✗'
      const color = t.status === 'running' ? C.blue : t.status === 'done' ? C.green : C.red
      return (
        <Box key={t.id} width="100%">
          <Box width="25%" paddingRight={GUTTER}>
            <Text color={color}>{`${mark} `}</Text>
            <Text color={t.status === 'running' ? C.text : C.subtle} wrap="truncate">
              {t.kind}
            </Text>
          </Box>
          <Box width="55%" paddingRight={GUTTER}>
            <Text color={C.subtle}>{t.status === 'running' ? 'running ' : 'finished '}</Text>
            <Text color={C.label}>{'[ '}</Text>
            <Text color={t.status === 'running' ? C.cyan : C.subtle} wrap="truncate">{t.label}</Text>
            <Text color={C.label}>{' ]'}</Text>
          </Box>
          <Box width="20%">
            <Text color={seconds === null ? C.label : C.text}>{seconds === null ? '—' : fmtSeconds(seconds)}</Text>
          </Box>
        </Box>
      )
    }

    if (compact) {
      // Folded, the whole row takes the session's colour (session-tint leaves its rule out, so
      // the band stays one row): labels, bars, figures and counts, behind a bar at the left edge.
      // Without that mod the row is grey. Warnings keep their own colours either way.
      const tint = await read($, sessionTint).catch(() => null)
      const ink = tint?.hex ?? C.text
      const inkSoft = tint?.hex ?? C.subtle
      const inkLabel = tint?.hex ?? C.label
      // CONTEXT ━───── 4%    5-HOUR ━━━─── 38%    WEEKLY ━━━─── 41%    SESSION ╱╱╱╱╱ $0.42    ▸
      // A •0  T •0  ▌ CONTEXT ━── 4%   5-HOUR ━── 45%   WEEKLY ━── 42%   SESSION ╱╱ $0.00   ▸
      // The agent and task counts sit before the colour bar; the four gauges share the rest equally.
      // The folded row follows its width in four steps, so nothing in it is ever cut off:
      // full labels and bars; short labels and bars; short labels and figures only; and, at its
      // tightest, each gauge only as wide as its text, wrapping onto a second row if it must,
      // with the agent and task counts left out while there is nothing to count.
      const fold: 'full' | 'short' | 'bare' | 'tight' = cells >= 120 ? 'full' : cells >= 84 ? 'short' : cells >= 60 ? 'bare' : 'tight'
      const hasBars = fold === 'full' || fold === 'short'
      const cell = (key: string, title: string, middle: JSX.Element, value: string, color: string) => (
        <Box key={key} width={fold === 'tight' ? undefined : '25%'} flexShrink={fold === 'tight' ? 0 : undefined} paddingRight={GUTTER} alignItems="center">
          {/* The label and the figure keep their full width; the bar between them is what gives way. */}
          <Box flexShrink={0} paddingRight={hasBars ? GUTTER : 0}>
            <Text color={inkLabel} bold>
              {fold === 'full' ? title : (SHORT[key] ?? title).toUpperCase()}
            </Text>
          </Box>
          {hasBars ? (
            <Box flexGrow={1} flexShrink={1} minWidth={0} overflow="hidden">
              {middle}
            </Box>
          ) : fold === 'bare' ? (
            <Box flexGrow={1} />
          ) : null}
          <Box flexShrink={0} paddingLeft={GUTTER}>
            <Text color={color} bold>
              {value}
            </Text>
          </Box>
        </Box>
      )
      // A gauge still turns amber from 70% and red from 90%, and a failure is still red.
      const gaugeCell = (key: string, title: string, pct: number | null) =>
        cell(
          key,
          title,
          bar(pct, inkSoft),
          pct === null ? '—' : `${Math.round(pct)}%`,
          pct === null ? C.label : gaugeColor(pct, ink),
        )
      // Agents and background tasks always have their own place at the start of the row, so
      // nothing shifts when one starts or ends and the session keeps its striped bar:
      // A •2 ✓1  T •0   (• running, always shown, dim at zero; ✓ finished and ✗ failed only
      // while there are any).
      const jobsFailed = jobs.filter(t => t.status === 'failed').length
      const marks = (key: string, letter: string, live: number, ended: number, bad: number) => (
        <Box key={key} paddingRight={2} flexShrink={0}>
          <Text color={inkLabel} bold>{`${letter} `}</Text>
          <Text color={live > 0 ? ink : C.label}>{`•${live}`}</Text>
          {ended > 0 ? <Text color={inkSoft}>{` ✓${ended}`}</Text> : null}
          {bad > 0 ? <Text color={C.red}>{` ✗${bad}`}</Text> : null}
        </Box>
      )
      const activity = fold === 'tight' && team.length === 0 && jobs.length === 0 ? null : (
        <Box alignItems="center" flexShrink={0}>
          {marks('agents', 'A', running, finished, failed)}
          {marks('tasks', 'T', jobsRunning, jobs.length - jobsRunning - jobsFailed, jobsFailed)}
        </Box>
      )
      return (
        <Box flexDirection="column" width="100%">
          {below}
          <Box width="100%">
            {mapIcon}
            {activity}
            {tint ? <Text color={tint.hex} bold>{'▌ '}</Text> : null}
            <Box flexGrow={1} flexShrink={1} minWidth={0} flexWrap={fold === 'tight' ? 'wrap' : 'nowrap'} rowGap={ROW}>
              {gaugeCell('context', 'CONTEXT', u.pct)}
              {gaugeCell('five_hour', '5-HOUR', limit('five_hour')?.pct ?? null)}
              {gaugeCell('seven_day', 'WEEKLY', limit('seven_day')?.pct ?? null)}
              {cell(
                'session',
                'SESSION',
                stripedBar(u.usd !== null ? inkSoft : null),
                u.usd !== null ? fmtUsd(u.usd) : '—',
                u.usd !== null ? ink : C.label,
              )}
            </Box>
            {graphIcon}
            {toggle}
          </Box>
        </Box>
      )
    }

    return (
      <Box flexDirection="column" width="100%">
        {below}
        <Box width="100%">
          {mapWord}
          <Box flexGrow={1} flexWrap={tier === 'narrow' ? 'wrap' : 'nowrap'} rowGap={ROW}>
          {gaugeColumn(
            'context',
            'Context',
            u.pct,
            C.blue,
            u.tokens !== null && u.window !== null
              ? tier === 'wide'
                ? `${u.isEstimated ? 'about ' : ''}${fmtTokens(u.tokens)} of ${fmtTokens(u.window)} tokens`
                : `${fmtTokens(u.tokens)} of ${fmtTokens(u.window)}`
              : tier === 'wide' ? 'after the next reply' : 'no reading',
          )}
          {limitColumn('five_hour')}
          {limitColumn('seven_day')}
          {column(
            'session',
            head(titleOf('session', 'Session'), u.usd !== null ? fmtUsd(u.usd) : '—', u.usd !== null ? C.green : C.label),
            stripedBar(u.usd !== null ? C.green : null),
            detail(lastTurn),
          )}
          </Box>
          {graphWord}
          {toggle}
        </Box>
        {team.length > 0 ? (
          <Box flexDirection="column" width="100%" marginTop={ROW}>
            <Box>
              <Text color={C.label} bold>{'AGENTS  '}</Text>
              <Text color={running > 0 ? C.blue : C.subtle}>{`${running} running`}</Text>
              <Text color={C.label}>{' · '}</Text>
              <Text color={finished > 0 ? C.green : C.subtle}>{`${finished} done`}</Text>
              {failed > 0 ? <Text color={C.red}>{` · ${failed} failed`}</Text> : null}
            </Box>
            {shown.map(agentRow)}
            {team.length > shown.length ? <Text color={C.label}>{`+ ${team.length - shown.length} more`}</Text> : null}
          </Box>
        ) : null}
        {jobs.length > 0 ? (
          <Box flexDirection="column" width="100%" marginTop={ROW}>
            <Box>
              <Text color={C.label} bold>{'BACKGROUND TASKS  '}</Text>
              <Text color={jobsRunning > 0 ? C.blue : C.subtle}>{`${jobsRunning} running`}</Text>
              <Text color={C.label}>{' · '}</Text>
              <Text color={jobs.length - jobsRunning > 0 ? C.green : C.subtle}>{`${jobs.length - jobsRunning} finished`}</Text>
            </Box>
            {jobs.slice(-MAX_TASKS_SHOWN).map(taskRow)}
            {jobs.length > MAX_TASKS_SHOWN ? <Text color={C.label}>{`+ ${jobs.length - MAX_TASKS_SHOWN} more`}</Text> : null}
          </Box>
        ) : null}
      </Box>
    )
  })
}
