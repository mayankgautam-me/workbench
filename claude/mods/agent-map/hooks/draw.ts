// The map as one SVG drawing: cards on a dot grid, top to bottom by dependency and filling the
// width, with arrows, the files and agents at work on each card, and a session card above.
// Pure: nothing here touches `$`.

import type { Area, AreaStat, MapAgent, PlanTask, MapTask } from '../types'
import { MAIN, fmtAgo, heatOf, planStatus, plural, rankAreas, shorten, verbOf } from './core'
import type { Heat } from './core'

// Tokyo Night, as the status band uses it.
export const C = {
  label: '#565f89',
  subtle: '#737aa2',
  text: '#c0caf5',
  soft: '#a9b1d6',
  track: '#3b4261',
  card: '#1f2335',
  ink: '#1a1b26',
  blue: '#7aa2f7',
  purple: '#bb9af7',
  cyan: '#7dcfff',
  green: '#9ece6a',
  amber: '#e0af68',
  red: '#f7768e',
  teal: '#73daca',
  orange: '#ff9e64',
}
// Amber is what is being worked on now; blue what was edited earlier this session.
export const HEAT: Record<Heat, string> = { live: C.amber, edited: C.blue, read: C.cyan, cold: C.label }
// The session is always the first colour; each subagent takes the next, so its mark on a
// card, its trail and its card in the list match.
export const AGENT_COLORS = [C.text, C.purple, C.green, C.orange, C.teal, C.red, C.cyan, C.blue]
export const agentColor = (team: readonly MapAgent[], id: string) =>
  AGENT_COLORS[Math.max(0, team.findIndex(a => a.id === id)) % AGENT_COLORS.length] as string

const SANS = `-apple-system, 'Helvetica Neue', 'Segoe UI', sans-serif`
const MONO = `ui-monospace, 'SF Mono', Menlo, monospace`
// One gap for the whole map, the same as the git graph's two cells across and one row down:
// round the drawing, between cards where no line runs, and inside a card on every side.
const G = 19
const PAD = G
const GAP = G
const INSET = G
// A card, top to bottom: its heading (tech, title, progress, bar), its tasks, the files last
// touched in it, and a row per agent working there. Every card in a row is as tall as the
// tallest, so rows stay aligned.
const HEAD_H = 83
const TASK_H = 18
const FILE_H = 16
const AGENT_H = 20
// A card lists every task of its component. The cap is only a guard for a runaway plan.
const MAX_TASKS = 200
const MAX_FILES = 3
// The order a card's task groups come in, and what each is called.
export const TASK_GROUPS = [['working', 'In progress'], ['stuck', 'Blocked'], ['todo', 'To do'], ['done', 'Done']] as const
const MAX_HERE = 3
const MAX_SESSION = 6
// Background tasks: the newest few on the session card, and the running ones on a component's card.
const MAX_BACKGROUND = 5
const MAX_BACKGROUND_HERE = 2
const MIN_CARD_W = 230
// A card this wide per column lists its tasks side by side, so a wide panel is used across
// before it is used down.
const TASK_COL_W = 270
// The two distances every line on the map keeps: CLEAR from the edge of any card it runs
// beside, and LINE from any line it runs beside.
const CLEAR = 16
const LINE = 12
const NARROW_W = 560
const NARROW_ZOOM = 1.25
// How long an agent's mark takes to glide from the card it left to the one it is on.
export const GLIDE_MS = 1200

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
const n = (x: number) => (Math.round(x * 10) / 10).toString()

// A task's words on at most two lines of `chars` characters, the second cut with an ellipsis.
const wrap = (text: string, chars: number): string[] => {
  if (text.length <= chars) return [text]
  const words = text.split(' ')
  let first = ''
  let i = 0
  for (; i < words.length; i++) {
    const next = first ? `${first} ${words[i]}` : (words[i] as string)
    if (next.length > chars) break
    first = next
  }
  // One word longer than the line: cut it there.
  if (!first) return [shorten(text, chars)]
  return [first, shorten(words.slice(i).join(' '), chars)]
}

export type MapDrawing = {
  source: string
  alt: string
  width: number
  height: number
}

type Point = [number, number]
type Box = { x: number; y: number; w: number; h: number; row: number }

export const drawMap = (input: {
  areas: readonly Area[]
  stats: Readonly<Record<string, AreaStat>>
  agents: readonly MapAgent[]
  /** What the session left running in the background, oldest first, with what has ended since the last prompt. */
  tasks?: readonly MapTask[]
  /** The width to lay out for, in CSS pixels. */
  width: number
  /** The time now: for "5s" beside a file, and so each redraw picks the motion up where the last left it. */
  now?: number
  /** Which task groups are unfolded: these statuses on every card, and every group of one card (`*` for all cards). */
  unfolded?: { states: readonly PlanTask['state'][]; card: string }
}): MapDrawing => {
  const { areas, stats, agents } = input
  const tasks = input.tasks ?? []
  const now = input.now ?? 0
  const unfolded = input.unfolded ?? { states: [], card: '' }
  const shown = Math.max(280, Math.min(1600, Math.round(input.width)))
  // Docked in a sidebar the panel is narrow: the map is laid out for a narrower width and
  // drawn larger, so the text stays readable. One column of cards, scrolled, not a shrunk grid.
  const zoom = shown < NARROW_W ? NARROW_ZOOM : 1
  const W = Math.round(shown / zoom)
  const rank = rankAreas(areas)
  const ranks = [...new Set(areas.map(a => rank.get(a.path) ?? 0))].sort((a, b) => a - b)
  // Only `needs` is drawn: a plan's looser `links` are kept in the file and left off the map.
  const linked = areas.some(a => (a.needs?.length ?? 0) > 0)
  const maxCols = Math.max(1, Math.min(5, Math.floor((W - 2 * PAD + GAP) / (MIN_CARD_W + GAP))))
  // In a single column every arrow would be a vertical line through the cards between its
  // ends, which says nothing: a narrow panel shows the cards in dependency order without them.
  const hasEdges = maxCols > 1 && linked
  // With arrows, the gaps between cards and rows are the channels the arrows run in.
  const grid = hasEdges ? { gapX: 2 * CLEAR, vgap: 2 * CLEAR, padX: CLEAR + 3 } : { gapX: GAP, vgap: 2 * CLEAR, padX: PAD }
  // The side margins: each grows by a line for every arrow that has to go round by it.
  let padL = grid.padX
  let padR = grid.padX
  const innerW = () => W - padL - padR

  // The drawing is redrawn whenever anything changes, which would start every motion over.
  // Each one is begun in the past by the time already run, so it carries on where it was.
  const phase = (periodMs: number) => (now > 0 ? ` begin="-${n((now % periodMs) / 1000)}s"` : '')

  // Who is where. An agent stays on the card it last worked in for as long as it is working:
  // while it thinks or runs a command that names no file, that card stays lit and says so.
  // Only an agent that has touched no component yet shows on the session card alone.
  const present = (a: MapAgent) => a.status === 'running' || a.doing !== null
  const hereOf = (id: string) => agents.filter(a => a.area === id)
  const liveOf = (id: string) => hereOf(id).filter(present)
  const isLive = (id: string) => liveOf(id).length > 0
  const working = agents.filter(present)
  // A background task is on the session card until the prompt after it ends, and on the card of
  // the component its command names for as long as it runs.
  const background = tasks.slice(-MAX_BACKGROUND)
  const tasksOn = (id: string) => tasks.filter(t => t.status === 'running' && t.area === id).slice(-MAX_BACKGROUND_HERE)
  const titleOf = (id: string | null) => {
    const a = areas.find(x => x.path === id)
    return a ? (a.title ?? a.path) : ''
  }
  // A card's files: the ones in flight now first, then the last few touched this session.
  const filesOf = (id: string) => {
    const recent = stats[id]?.recent ?? []
    const flying = [...new Set(liveOf(id).map(a => (a.doing !== null ? (a.file ?? null) : null)).filter((f): f is string => !!f))]
    return [...flying.filter(f => !recent.some(r => r.file === f)).map(file => ({ file, reads: 0, edits: 0, at: 0 })), ...recent]
      .slice(0, MAX_FILES)
      .map(r => ({ ...r, isActive: flying.includes(r.file) }))
  }

  // Rows are the ranks of the `needs` graph, top to bottom. The cards of a row share the full
  // width between them, so nothing is left empty beside a short row; a rank too long for one
  // row is split into even ones.
  const pos = new Map<string, Box>()
  const rows: Area[][] = []
  const needed = new Set(areas.flatMap(a => a.needs ?? []))
  const joined = (a: Area) => needed.has(a.path) || (a.needs?.length ?? 0) > 0
  for (const r of ranks) {
    const inRank = areas.filter(a => (rank.get(a.path) ?? 0) === r)
    // A card nothing depends on and that needs nothing (loose docs, unplanned files) goes last.
    const ordered = [...inRank.filter(joined), ...inRank.filter(a => !joined(a))]
    const per = Math.ceil(ordered.length / Math.ceil(ordered.length / maxCols))
    for (let i = 0; i < ordered.length; i += per) rows.push(ordered.slice(i, i + per))
  }
  // The order within each row is settled for the arrows: a card moves toward the cards it is
  // joined to in the rows above and below, pass by pass, so arrows run short and cross little.
  if (hasEdges) {
    const rowOf = new Map<string, number>()
    rows.forEach((row, r) => row.forEach(a => rowOf.set(a.path, r)))
    const place = new Map<string, number>()
    const settle = (row: Area[]) => row.forEach((a, k) => place.set(a.path, (k + 0.5) / row.length))
    rows.forEach(settle)
    const dependents = new Map<string, string[]>()
    for (const a of areas) for (const need of a.needs ?? []) dependents.set(need, [...(dependents.get(need) ?? []), a.path])
    const sweep = (order: number[], near: (a: Area) => readonly string[]) => {
      for (const r of order) {
        const row = rows[r] as Area[]
        const want = new Map(
          row.map(a => {
            const at = near(a).filter(id => rowOf.get(id) !== r).map(id => place.get(id)).filter((x): x is number => x !== undefined)
            return [a.path, !joined(a) ? 2 : at.length > 0 ? at.reduce((sum, x) => sum + x, 0) / at.length : (place.get(a.path) ?? 0.5)] as const
          }),
        )
        row.sort((a, b) => (want.get(a.path) ?? 0) - (want.get(b.path) ?? 0))
        settle(row)
      }
    }
    const down = rows.map((_, i) => i)
    const up = [...down].reverse()
    const above = (a: Area) => a.needs ?? []
    const below = (a: Area) => dependents.get(a.path) ?? []
    sweep(down, above)
    sweep(up, below)
    sweep(down, above)
  }

  // The arrows, planned before the rows are given their heights. Every arrow that leaves a
  // card shares one trunk: down from the card into the gap beneath it, along a track of its
  // own there, and down into each card that needs it. So a gap holds one line per source, not
  // one per arrow, and it is made as tall as its tracks need. An arrow enters its target
  // straight below where it left when the two overlap, and at the nearest point otherwise;
  // arrows into one card keep apart along its edge.
  type Wire = { from: string; to: string; x1: number; x2: number; side: number | null; isNeed: boolean }
  // Along a card's edge, from its corner: a trail, then a link to a neighbour, then the arrows.
  const TRAIL_IN = CLEAR
  // The agents on the move: each has a line from the card it left to the one it is on. Every
  // such line gets a place of its own, LINE from the next: along a card's edge, in a gap, and
  // in the left margin. Arrows start further along the edge and further into the gap.
  const rowOf = new Map<string, number>()
  rows.forEach((inRow, r) => inRow.forEach(a => rowOf.set(a.path, r)))
  const movers = agents.filter(present).flatMap(a => {
    const [from, to] = (a.trail ?? []).slice(-2)
    return from && to && from !== to && rowOf.has(from) && rowOf.has(to) ? [{ id: a.id, from, to }] : []
  })
  const slotOf = new Map<string, number>()
  const perCard = new Map<string, number>()
  for (const m of movers) {
    for (const card of [m.from, m.to]) {
      const slot = perCard.get(card) ?? 0
      slotOf.set(`${m.id}:${card}`, slot)
      perCard.set(card, slot + 1)
    }
  }
  const extraIn = Math.max(1, ...perCard.values()) - 1
  const SIDE_IN = CLEAR + LINE * (1 + extraIn)
  const PORT_IN = CLEAR + LINE * (2 + extraIn)
  const trailX = (id: string, path: string) => (pos.get(path) as Box).x + TRAIL_IN + LINE * (slotOf.get(`${id}:${path}`) ?? 0)
  // How each mover's line runs: straight down, along the gap under the upper card, round by
  // the left margin where a card is in the way, or under the row for two cards side by side.
  type Route = { id: string; up: string; down: string; kind: 'drop' | 'strip' | 'side' | 'row'; isReversed: boolean }
  const routesNow = (): Route[] =>
    movers.map(m => {
      const a = pos.get(m.from) as Box, b = pos.get(m.to) as Box
      if (a.row === b.row) return { id: m.id, up: m.from, down: m.to, kind: 'row', isReversed: false }
      const isReversed = a.row > b.row
      const [up, down] = isReversed ? [m.to, m.from] : [m.from, m.to]
      const f = pos.get(up) as Box, t = pos.get(down) as Box
      const fx = trailX(m.id, up), tx = trailX(m.id, down)
      const kind = t.row === f.row + 1 && Math.abs(fx - tx) < 1 ? 'drop' : t.row === f.row + 1 || !blocked(tx, f.row, t.row) ? 'strip' : 'side'
      return { id: m.id, up, down, kind, isReversed }
    })
  // The lines the left margin holds for movers; an arrow that goes round by it starts beyond them.
  let sideLines = 1
  const clamp = (x: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, x))
  const blocked = (x: number, fromRow: number, toRow: number) =>
    [...pos.values()].some(b => b.row > fromRow && b.row < toRow && x > b.x - CLEAR + 1 && x < b.x + b.w + CLEAR - 1)
  const wires: Wire[] = []
  // Lays the cards out for the margins as they stand and plans every wire; says how many
  // sources go round by each margin, so the margins can be made to fit them and the plan redone.
  const plan = () => {
    pos.clear()
    wires.length = 0
    rows.forEach((inRow, r) => {
      const w = Math.floor((innerW() - (inRow.length - 1) * grid.gapX) / inRow.length)
      inRow.forEach((a, k) => pos.set(a.path, { x: padL + k * (w + grid.gapX), y: 0, w, h: 0, row: r }))
    })
    const round = { l: 0, r: 0 }
    if (!hasEdges) return round
    const pairs: { from: string; to: string; isNeed: boolean }[] = []
    for (const a of areas) {
      for (const need of a.needs ?? []) pairs.push({ from: need, to: a.path, isNeed: true })
    }
    // Always drawn from the upper card to the lower; two cards in one row are joined at the side.
    const sorted = pairs
      .filter(e => pos.has(e.from) && pos.has(e.to) && e.from !== e.to)
      .map(e => ((pos.get(e.from) as Box).row > (pos.get(e.to) as Box).row ? { ...e, from: e.to, to: e.from } : e))
    const leaving = new Map<string, string[]>()
    for (const e of sorted) if ((pos.get(e.from) as Box).row !== (pos.get(e.to) as Box).row) leaving.set(e.from, [...(leaving.get(e.from) ?? []), e.to])
    // Where a card's trunk leaves it: its middle, or over its one target when it has only one.
    const exit = (id: string) => {
      const f = pos.get(id) as Box
      const targets = leaving.get(id) ?? []
      const only = targets.length === 1 ? (pos.get(targets[0] as string) as Box) : null
      return only ? clamp(only.x + only.w / 2, f.x + PORT_IN, f.x + f.w - PORT_IN) : f.x + f.w / 2
    }
    const into = new Map<string, typeof sorted>()
    for (const e of sorted) into.set(e.to, [...(into.get(e.to) ?? []), e])
    const sides = new Map<string, number>()
    for (const [to, list] of into) {
      const t = pos.get(to) as Box
      const vertical = list.filter(e => (pos.get(e.from) as Box).row !== t.row).sort((a, b) => exit(a.from) - exit(b.from))
      const lo = t.x + PORT_IN, hi = t.x + t.w - PORT_IN
      const ports = vertical.map(e => clamp(exit(e.from), lo, hi))
      for (let i = 1; i < ports.length; i++) ports[i] = Math.max(ports[i] as number, (ports[i - 1] as number) + LINE)
      const over = Math.max(0, (ports[ports.length - 1] ?? lo) - hi)
      for (let i = ports.length - 1; i >= 0; i--) ports[i] = Math.max(lo, Math.min((ports[i] as number) - over, i < ports.length - 1 ? (ports[i + 1] as number) - Math.min(LINE, (hi - lo) / ports.length) : hi))
      vertical.forEach((e, i) => {
        const f = pos.get(e.from) as Box
        const x2 = ports[i] as number
        let side: number | null = null
        if (t.row > f.row + 1 && blocked(x2, f.row, t.row)) {
          // Round by the nearer margin, each source on a line of its own there.
          const left = x2 < W / 2
          const key = `${left ? 'l' : 'r'}:${e.from}`
          if (!sides.has(key)) {
            sides.set(key, left ? round.l : round.r)
            if (left) round.l += 1
            else round.r += 1
          }
          // The left margin's first line is kept for trails; arrows take the next ones out.
          const k = sides.get(key) as number
          side = left ? Math.max(3, padL - CLEAR - LINE * (k + sideLines)) : Math.min(W - 3, W - padR + CLEAR + LINE * k)
        }
        wires.push({ ...e, x1: exit(e.from), x2, side })
      })
      // Two cards of one row are joined under the row: out of the bottom of each, by the ends
      // that face each other, and along a track of the gap beneath. Never across a card.
      for (const e of list.filter(x => (pos.get(x.from) as Box).row === t.row)) {
        const f = pos.get(e.from) as Box
        const [l, r] = f.x < t.x ? [f, t] : [t, f]
        wires.push({ ...e, x1: l.x + l.w - SIDE_IN, x2: r.x + SIDE_IN, side: null })
      }
    }
    return round
  }
  {
    const round = plan()
    sideLines = Math.max(1, routesNow().filter(x => x.kind === 'side').length)
    padL = CLEAR + LINE * (round.l + sideLines - 1) + 3
    padR = round.r > 0 ? CLEAR + LINE * (round.r - 1) + 3 : grid.padX
  }
  plan()
  const routes = routesNow()
  const sideIds = routes.filter(x => x.kind === 'side').map(x => x.id)
  // The movers' lines in each gap, in the order they are drawn.
  const strips: string[][] = rows.map(() => [])
  for (const x of routes) {
    const f = pos.get(x.up) as Box, t = pos.get(x.down) as Box
    if (x.kind !== 'drop') (strips[f.row] as string[]).push(x.id)
    if (x.kind === 'side' && t.row - 1 !== f.row) (strips[t.row - 1] as string[]).push(x.id)
  }
  const stripLines = (r: number) => Math.max(1, (strips[r] as string[]).length)

  // The tracks of each gap, one per source that runs a line through it, left to right.
  const tracks: string[][] = rows.map(() => [])
  const trackX = new Map<string, number>()
  const keyOf = (w: Wire) => ((pos.get(w.from) as Box).row === (pos.get(w.to) as Box).row ? `~${w.from}~${w.to}` : w.from)
  for (const w of wires) {
    const f = pos.get(w.from) as Box, t = pos.get(w.to) as Box
    const key = keyOf(w)
    const use = (row: number) => {
      if (!(tracks[row] as string[]).includes(key)) (tracks[row] as string[]).push(key)
    }
    if (f.row === t.row) {
      trackX.set(key, w.x1)
      use(f.row)
      continue
    }
    trackX.set(key, f.x)
    // A straight drop into the next row needs no track.
    if (!(t.row === f.row + 1 && Math.abs(w.x1 - w.x2) < 1)) use(f.row)
    if (w.side !== null) use(t.row - 1)
  }
  tracks.forEach(list => list.sort((a, b) => (trackX.get(a) ?? 0) - (trackX.get(b) ?? 0)))
  // A gap, top to bottom: CLEAR under the cards, the strip kept for the trails of agents on the
  // move, a track LINE apart for each source, and CLEAR above the next row for the arrowheads.
  const gapAfter = (r: number) => 2 * CLEAR + (stripLines(r) - 1 + (tracks[r] as string[]).length) * LINE

  // A card's tasks, in as many columns as its width holds.
  // A card's tasks, grouped by status in the order that matters now: in progress, blocked, to
  // do, done. A group is one line, its name and count, until it is unfolded; then its tasks
  // follow it. Many lines spread over as many columns as the card's width holds.
  type Entry = { isHead: boolean; state: PlanTask['state']; lines: string[]; isOpen: boolean }
  const tasksOf = (a: Area, w: number) => {
    const list = (a.taskList ?? []).slice(0, MAX_TASKS)
    const openAll = unfolded.card === '*' || unfolded.card === a.path
    const build = (chars: number): Entry[] =>
      TASK_GROUPS.flatMap(([state, label]) => {
        const mine = list.filter(t => t.state === state)
        if (mine.length === 0) return []
        // What is being worked on is always listed: it is what the map is watched for.
        const isOpen = openAll || state === 'working' || unfolded.states.includes(state)
        return [
          { isHead: true, state, lines: [`${label} · ${mine.length}`], isOpen },
          ...(isOpen ? mine.map(t => ({ isHead: false, state, lines: wrap(t.text, chars), isOpen })) : []),
        ]
      })
    const charsFor = (cols: number) => Math.max(8, Math.floor(((w - 2 * INSET) / cols - 22) / 5.5))
    const total = (entries: Entry[]) => entries.reduce((sum, e) => sum + e.lines.length, 0)
    // More than a handful of lines: side by side, where the card is wide enough.
    const colCount = Math.max(1, Math.min(Math.floor((w - 2 * INSET) / TASK_COL_W), Math.ceil(total(build(charsFor(1))) / 6)))
    const entries = build(charsFor(colCount))
    const target = Math.ceil(total(entries) / colCount)
    const columns: Entry[][] = [[]]
    let filled = 0
    for (const entry of entries) {
      if (filled >= target && columns.length < colCount) {
        columns.push([])
        filled = 0
      }
      ;(columns[columns.length - 1] as Entry[]).push(entry)
      filled += entry.lines.length
    }
    return { columns, colW: (w - 2 * INSET) / colCount, lines: Math.max(0, ...columns.map(total)) }
  }
  const heightOf = (a: Area, w: number) => {
    const lines = tasksOf(a, w).lines
    const files = filesOf(a.path).length
    return (
      HEAD_H + (lines > 0 ? lines * TASK_H + 8 : 0) + (files > 0 ? files * FILE_H + 12 : 0) +
      // A row per agent working here, and none kept for one that is not: the card is as tall as what it shows.
      (Math.min(MAX_HERE, liveOf(a.path).length) + tasksOn(a.path).length) * AGENT_H + 13
    )
  }
  // The session card, above the map while anything is working: every agent and what it is doing.
  const sessionRows = Math.min(MAX_SESSION, working.length)
  const agentLines = sessionRows + (working.length > MAX_SESSION ? 1 : 0)
  const taskLines = background.length + (tasks.length > MAX_BACKGROUND ? 1 : 0)
  const sessionH = agentLines + taskLines > 0 ? (agentLines + taskLines) * AGENT_H + 26 : 0
  const top = PAD + (sessionH > 0 ? sessionH + GAP : 0)
  const rowH = rows.map(inRow => Math.max(...inRow.map(a => heightOf(a, (pos.get(a.path) as Box).w))))
  const rowY = (r: number) => top + rowH.slice(0, r).reduce((sum, h, i) => sum + h + gapAfter(i), 0)
  for (const b of pos.values()) {
    b.y = rowY(b.row)
    b.h = rowH[b.row] as number
  }
  // The last row has no gap beneath it: room is kept there for a trail and any line under it.
  const under = rows.length > 0 ? (tracks[rows.length - 1] as string[]).length : 0
  const lastTracks = rows.length > 0 ? (stripLines(rows.length - 1) - 1 + under) * LINE : 0
  const H = Math.max(HEAD_H + AGENT_H + 2 * PAD, rowY(rows.length) - (rows.length > 0 ? gapAfter(rows.length - 1) : 0) + PAD + lastTracks)

  // A wire's corners, now the rows have their heights. It runs only in the gaps, so no arrow
  // ever passes behind a card.
  const trackY = (row: number, from: string) => {
    const list = tracks[row] as string[]
    const bottom = rowY(row) + (rowH[row] as number)
    return bottom + CLEAR + LINE * (stripLines(row) + Math.max(0, list.indexOf(from)))
  }
  const route = (w: Wire): Point[] => {
    const f = pos.get(w.from) as Box, t = pos.get(w.to) as Box
    if (f.row === t.row) {
      const ty = trackY(f.row, keyOf(w))
      return [[w.x1, f.y + f.h], [w.x1, ty], [w.x2, ty], [w.x2, t.y + t.h]]
    }
    const y1 = f.y + f.h, y2 = t.y
    if (t.row === f.row + 1 && Math.abs(w.x1 - w.x2) < 1) return [[w.x1, y1], [w.x2, y2]]
    const ty = trackY(f.row, w.from)
    if (w.side === null) return [[w.x1, y1], [w.x1, ty], [w.x2, ty], [w.x2, y2]]
    const ty2 = trackY(t.row - 1, w.from)
    return [[w.x1, y1], [w.x1, ty], [w.side, ty], [w.side, ty2], [w.x2, ty2], [w.x2, y2]]
  }
  // The path through those points, each corner rounded.
  const trace = (points: Point[]) => {
    const pts = points.filter((p, i) => i === 0 || p[0] !== (points[i - 1] as Point)[0] || p[1] !== (points[i - 1] as Point)[1])
    let d = `M${n((pts[0] as Point)[0])} ${n((pts[0] as Point)[1])}`
    for (let i = 1; i < pts.length - 1; i++) {
      const a = pts[i - 1] as Point, p = pts[i] as Point, b = pts[i + 1] as Point
      const la = Math.hypot(p[0] - a[0], p[1] - a[1]), lb = Math.hypot(b[0] - p[0], b[1] - p[1])
      const r = Math.min(7, la / 2, lb / 2)
      d +=
        ` L${n(p[0] - ((p[0] - a[0]) / la) * r)} ${n(p[1] - ((p[1] - a[1]) / la) * r)}` +
        ` Q${n(p[0])} ${n(p[1])} ${n(p[0] + ((b[0] - p[0]) / lb) * r)} ${n(p[1] + ((b[1] - p[1]) / lb) * r)}`
    }
    const last = pts[pts.length - 1] as Point
    return `${d} L${n(last[0])} ${n(last[1])}`
  }

  // An agent's mark: a dot in its colour, with a ring that spreads from it while a call is in flight.
  const dot = (a: MapAgent, cx: number, cy: number) => {
    const color = agentColor(agents, a.id)
    // Quick while a call is in flight, slow while it thinks: something always moves for an agent at work.
    const ms = a.doing !== null ? 1200 : 2400
    const ring = present(a)
      ? `<circle cx="${n(cx)}" cy="${n(cy)}" r="4.5" fill="none" stroke="${color}" stroke-width="1.5">` +
        `<animate attributeName="r" values="4.5;10" dur="${n(ms / 1000)}s" repeatCount="indefinite"${phase(ms)}/>` +
        `<animate attributeName="opacity" values="0.7;0" dur="${n(ms / 1000)}s" repeatCount="indefinite"${phase(ms)}/></circle>`
      : ''
    return `${ring}<circle cx="${n(cx)}" cy="${n(cy)}" r="4.5" fill="${color}"/>`
  }
  const nameOf = (a: MapAgent) => (a.id === MAIN ? 'session' : a.name.trim() || 'agent')
  // One agent in words: its mark, its name, and what it is doing now.
  const agentRow = (a: MapAgent, x: number, y: number, room: number, where: string) => {
    const name = shorten(nameOf(a), 16)
    const nameW = name.length * 6.1 + 8
    const whereW = where ? Math.min(where.length, 22) * 5.6 + 10 : 0
    const doing = a.doing ?? 'thinking'
    const chars = Math.max(4, Math.floor((room - 14 - nameW - whereW) / 6.4))
    return (
      dot(a, x + 5, y) +
      `<text x="${n(x + 15)}" y="${n(y + 3.7)}" font-family="${SANS}" font-size="10.5" font-weight="600" fill="${agentColor(agents, a.id)}">${esc(name)}</text>` +
      `<text x="${n(x + 15 + nameW)}" y="${n(y + 3.7)}" font-family="${MONO}" font-size="10.5" font-weight="500" ` +
      `fill="${a.doing !== null ? C.amber : C.label}">${esc(shorten(doing, chars))}</text>` +
      (where
        ? `<text x="${n(x + room)}" y="${n(y + 3.7)}" text-anchor="end" font-family="${SANS}" font-size="10.5" fill="${C.subtle}">${esc(shorten(where, 22))}</text>`
        : '')
    )
  }
  // A background task in words: a hollow square in the colour of its state, its kind, its
  // command, and at the right how long it has run or how it ended. The square of a running one
  // fades in and out, slower than an agent's ring: it is at work, but nobody is watching it.
  const TASK_COLOR = { running: C.cyan, done: C.green, failed: C.red, stopped: C.label } as const
  const taskRow = (t: MapTask, x: number, y: number, room: number, where: string) => {
    const color = TASK_COLOR[t.status]
    const isRunning = t.status === 'running'
    const kind = shorten(t.kind, 12)
    const kindW = kind.length * 6.1 + 8
    const ran = t.startedAt === null ? '' : fmtAgo((t.endedAt ?? now) - t.startedAt)
    const tail = [isRunning ? ran : `${t.status}${ran ? ` after ${ran}` : ''}`, where].filter(Boolean).join('  ·  ')
    const tailW = tail.length * 5.6 + 10
    const chars = Math.max(4, Math.floor((room - 14 - kindW - tailW) / 6.4))
    return (
      `<rect x="${n(x + 1)}" y="${n(y - 4)}" width="8" height="8" rx="2" fill="none" stroke="${color}" stroke-width="1.5">` +
      (isRunning ? `<animate attributeName="opacity" values="1;0.35;1" dur="3.2s" repeatCount="indefinite"${phase(3200)}/>` : '') +
      `</rect>` +
      `<text x="${n(x + 15)}" y="${n(y + 3.7)}" font-family="${SANS}" font-size="10.5" font-weight="600" fill="${color}">${esc(kind)}</text>` +
      `<text x="${n(x + 15 + kindW)}" y="${n(y + 3.7)}" font-family="${MONO}" font-size="10.5" font-weight="500" ` +
      `fill="${isRunning ? C.soft : C.label}">${esc(shorten(t.what, chars))}</text>` +
      `<text x="${n(x + room)}" y="${n(y + 3.7)}" text-anchor="end" font-family="${SANS}" font-size="10.5" fill="${C.subtle}">${esc(tail)}</text>`
    )
  }

  let out = ''
  if (sessionH > 0) {
    // The session card breathes for as long as anything is working, whatever it is.
    if (working.length > 0 || tasks.some(t => t.status === 'running'))
      out +=
        `<rect x="${n(padL - 3)}" y="${PAD - 3}" width="${n(innerW() + 6)}" height="${sessionH + 6}" rx="13" fill="none" stroke="${C.amber}" stroke-width="3" opacity="0.3">` +
        `<animate attributeName="opacity" values="0.4;0.04;0.4" dur="2.4s" repeatCount="indefinite"${phase(2400)}/></rect>`
    out +=
      `<rect x="${n(padL)}" y="${PAD}" width="${n(innerW())}" height="${sessionH}" rx="10" fill="${C.card}" stroke="${C.track}" stroke-width="1"/>`
    working.slice(0, MAX_SESSION).forEach((a, i) => {
      const where = a.area ? titleOf(a.area) : ''
      out += agentRow(a, padL + INSET, PAD + 13 + AGENT_H / 2 + i * AGENT_H, innerW() - 2 * INSET, where ? `in ${where}` : '')
    })
    if (working.length > MAX_SESSION)
      out +=
        `<text x="${n(padL + INSET + 15)}" y="${n(PAD + 13 + AGENT_H / 2 + MAX_SESSION * AGENT_H + 3.7)}" font-family="${SANS}" font-size="10.5" ` +
        `fill="${C.label}">${working.length - MAX_SESSION} more working</text>`
    // Under the agents: what runs in the background, and what of it has ended since the last prompt.
    const taskY = (i: number) => PAD + 13 + AGENT_H / 2 + (agentLines + i) * AGENT_H
    background.forEach((t, i) => {
      const where = t.area ? titleOf(t.area) : ''
      out += taskRow(t, padL + INSET, taskY(i), innerW() - 2 * INSET, where ? `in ${shorten(where, 22)}` : '')
    })
    if (tasks.length > MAX_BACKGROUND)
      out +=
        `<text x="${n(padL + INSET + 15)}" y="${n(taskY(background.length) + 3.7)}" font-family="${SANS}" font-size="10.5" ` +
        `fill="${C.label}">${tasks.length - MAX_BACKGROUND} more in the background</text>`
  }

  // Each agent's trail: a dotted line in its colour from the card it came from to the one it
  // is on, while it is working. Like the arrows it keeps to the gaps and turns at right angles:
  // out of the card by its corner, clear of where arrows enter, along the strip just under a
  // row, and into the other card. Only the last move is drawn, and it goes when the agent stops.
  const strip = (row: number, id: string) => rowY(row) + (rowH[row] as number) + CLEAR + LINE * Math.max(0, (strips[row] as string[]).indexOf(id))
  const trailOf = (a: MapAgent): Point[] | null => {
    const x = routes.find(r => r.id === a.id)
    if (!x) return null
    const f = pos.get(x.up) as Box, t = pos.get(x.down) as Box
    const fx = trailX(x.id, x.up), tx = trailX(x.id, x.down)
    // Two cards of one row: under the row and back up.
    if (x.kind === 'row') return [[fx, f.y + f.h], [fx, strip(f.row, x.id)], [tx, strip(f.row, x.id)], [tx, t.y + t.h]]
    const side = Math.max(3, padL - CLEAR - LINE * Math.max(0, sideIds.indexOf(x.id)))
    const down: Point[] =
      x.kind === 'drop'
        ? [[fx, f.y + f.h], [tx, t.y]]
        : x.kind === 'strip'
          ? [[fx, f.y + f.h], [fx, strip(f.row, x.id)], [tx, strip(f.row, x.id)], [tx, t.y]]
          : [[fx, f.y + f.h], [fx, strip(f.row, x.id)], [side, strip(f.row, x.id)], [side, strip(t.row - 1, x.id)], [tx, strip(t.row - 1, x.id)], [tx, t.y]]
    return x.isReversed ? down.reverse() : down
  }
  // A move is the one thing between cards that is drawn moving: dashes in the agent's colour
  // running the way it went, ending in an arrowhead at the card it is on now.
  const trails = new Map<string, string>()
  const moves: string[] = []
  for (const a of agents.filter(present)) {
    const points = trailOf(a)
    if (!points) continue
    // Stop just short of the card so the arrowhead's tip touches its edge.
    const end = points[points.length - 1] as Point, before = points[points.length - 2] as Point
    const len = Math.hypot(end[0] - before[0], end[1] - before[1]) || 1
    const d = trace([...points.slice(0, -1), [end[0] - ((end[0] - before[0]) / len) * 2, end[1] - ((end[1] - before[1]) / len) * 2]])
    trails.set(a.id, d)
    const k = Math.max(0, agents.findIndex(x => x.id === a.id)) % AGENT_COLORS.length
    moves.push(
      `<path d="${d}" fill="none" stroke="${C.ink}" stroke-width="5" stroke-linecap="round"/>` +
        `<path d="${d}" fill="none" stroke="${agentColor(agents, a.id)}" stroke-width="2" stroke-dasharray="6 6" stroke-linecap="round" ` +
        `stroke-linejoin="round" marker-end="url(#move-${k})">` +
        `<animate attributeName="stroke-dashoffset" from="24" to="0" dur="1s" repeatCount="indefinite"${phase(1000)}/></path>`,
    )
  }

  // The arrows of the plan, before the cards so the cards sit on top. An arrow says only that
  // the card it points at needs the card it comes from: it is part of the plan, so it is drawn
  // still and grey whatever is being worked on. The agents' moves go over them.
  for (const w of wires) {
    if (!w.isNeed) continue
    const points = route(w)
    // Stop just short of the card so the arrowhead's tip touches its edge.
    const end = points[points.length - 1] as Point
    out += `<path d="${trace([...points.slice(0, -1), [end[0], end[1] - 2]])}" fill="none" stroke="${C.track}" stroke-width="1.5" marker-end="url(#arrow)"/>`
  }
  out += moves.join('')
  const largest = Math.max(1, ...areas.map(a => a.files))
  // Where each agent's row sits on its card, for the mark that glides there.
  const seat = new Map<string, Point>()
  for (const a of areas) {
    const p = pos.get(a.path)
    if (!p) continue
    const cw = p.w
    const stat = stats[a.path]
    const live = liveOf(a.path)
    const heat = heatOf(stat, live.length > 0)
    const color = HEAT[heat]
    const special = a.kind === 'knowledge' ? C.purple : a.kind === 'human' ? C.teal : null
    // A card's edge is lit only while someone is working in it; what happened here earlier is
    // told by its counts and its files.
    const stroke = heat === 'live' ? C.amber : (special ?? C.track)
    // The card being worked on breathes: a soft amber edge outside its own.
    if (heat === 'live')
      out +=
        `<rect x="${n(p.x - 3)}" y="${n(p.y - 3)}" width="${n(cw + 6)}" height="${n(p.h + 6)}" rx="13" fill="none" stroke="${C.amber}" stroke-width="3" opacity="0.4">` +
        `<animate attributeName="opacity" values="0.5;0.06;0.5" dur="1.8s" repeatCount="indefinite"${phase(1800)}/></rect>`
    out +=
      `<rect x="${n(p.x)}" y="${n(p.y)}" width="${n(cw)}" height="${n(p.h)}" rx="10" fill="${heat === 'live' ? '#26283a' : C.card}" stroke="${stroke}" ` +
      `stroke-width="${heat === 'live' || special ? 1.5 : 1}"${a.kind === 'human' ? ' stroke-dasharray="7 5"' : ''}/>`

    const t = a.tasks && a.tasks.total > 0 ? a.tasks : null
    const complete = t !== null && t.done === t.total
    const left = p.x + INSET, right = p.x + cw - INSET
    const room = cw - 2 * INSET

    // Top right: a check for a finished component, a progress ring for one under way, a heat
    // dot for a card with no tasks. Left of it, while someone works here, what they are doing
    // in a word, and a spinner.
    const rx = right - 6, ry = p.y + 23
    if (complete) {
      out +=
        `<circle cx="${n(rx)}" cy="${n(ry)}" r="7" fill="${C.green}"/>` +
        `<path d="M${n(rx - 3.2)} ${n(ry + 0.2)} l2.3 2.4 l4.2 -4.8" fill="none" stroke="${C.ink}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>`
    } else if (t) {
      const r = 6.5, around = 2 * Math.PI * r
      out += `<circle cx="${n(rx)}" cy="${n(ry)}" r="${r}" fill="none" stroke="${C.track}" stroke-width="2"/>`
      if (t.done > 0)
        out +=
          `<circle cx="${n(rx)}" cy="${n(ry)}" r="${r}" fill="none" stroke="${heat === 'live' ? C.amber : C.green}" stroke-width="2" stroke-linecap="round" ` +
          `stroke-dasharray="${n((around * t.done) / t.total)} ${n(around)}" transform="rotate(-90 ${n(rx)} ${n(ry)})"/>`
      if (t.stuck > 0) out += `<circle cx="${n(rx)}" cy="${n(ry)}" r="2.5" fill="${C.red}"/>`
    } else {
      out += `<circle cx="${n(rx)}" cy="${n(ry)}" r="4" fill="${heat === 'cold' ? C.track : color}"/>`
    }
    const busy = live.find(m => m.doing !== null)
    const verb = live.length === 0 ? '' : busy ? verbOf(busy.lastTool) : 'Thinking'
    const verbW = verb ? verb.length * 6.2 + 20 : 0
    if (verb) {
      const sx = rx - 13 - verb.length * 6.2 - 9
      out +=
        `<text x="${n(rx - 13)}" y="${n(ry + 3.6)}" text-anchor="end" font-family="${SANS}" font-size="10.5" font-weight="600" ` +
        `fill="${C.amber}">${verb}</text>` +
        `<circle cx="${n(sx)}" cy="${n(ry)}" r="4.2" fill="none" stroke="${C.amber}" stroke-width="1.6" stroke-linecap="round" stroke-dasharray="13 27">` +
        `<animateTransform attributeName="transform" type="rotate" from="0 ${n(sx)} ${n(ry)}" to="360 ${n(sx)} ${n(ry)}" dur="0.9s" repeatCount="indefinite"${phase(900)}/></circle>`
    }

    // First line: the component's tech in small mono, or the card's id.
    const techRoom = Math.max(4, Math.floor((room - 22 - verbW) / 5.8))
    out +=
      `<text x="${n(left)}" y="${n(p.y + 26)}" font-family="${MONO}" font-size="9.5" fill="${C.label}">` +
      `${esc(shorten(a.tech ?? (a.title ? `#${a.path}` : a.files > 0 ? plural(a.files, 'file') : '—'), techRoom))}</text>`

    out +=
      `<text x="${n(left)}" y="${n(p.y + 47)}" font-family="${SANS}" font-size="13.5" font-weight="600" ` +
      `fill="${heat === 'cold' && !complete ? C.subtle : C.text}">${esc(shorten(a.title ?? a.path, Math.max(6, Math.floor(room / 7.4))))}</text>`

    // Third line: progress in words, then what happened here this session.
    const activity = !stat
      ? ''
      : [stat.edits > 0 ? plural(stat.edits, 'edit') : '', stat.reads > 0 ? plural(stat.reads, 'read') : ''].filter(Boolean).join(' · ')
    const progress = t ? `${t.done} of ${t.total} tasks · ${planStatus(t)}` : activity || (a.tech && a.files > 0 ? plural(a.files, 'file') : '')
    if (progress)
      out +=
        `<text x="${n(left)}" y="${n(p.y + 65)}" font-family="${SANS}" font-size="11" fill="${t ? C.subtle : activity ? color : C.label}">` +
        `${esc(shorten(progress, Math.max(6, Math.floor(room / 5.7))))}</text>`
    if (t && activity && room > progress.length * 5.7 + activity.length * 5.7 + 16)
      out += `<text x="${n(right)}" y="${n(p.y + 65)}" text-anchor="end" font-family="${SANS}" font-size="11" fill="${color}">${esc(activity)}</text>`

    // The bar: tasks done for a component, the card's share of the files otherwise.
    const share = t ? t.done / t.total : a.files / largest
    const fill = t ? (complete ? C.green : heat === 'live' ? C.amber : C.blue) : heat === 'cold' ? C.label : color
    out += `<rect x="${n(left)}" y="${n(p.y + 75)}" width="${n(room)}" height="3" rx="1.5" fill="${C.track}"/>`
    if (share > 0) out += `<rect x="${n(left)}" y="${n(p.y + 75)}" width="${n(Math.max(3, room * Math.min(1, share)))}" height="3" rx="1.5" fill="${fill}"/>`

    // The component's tasks, in the plan's order: done, working now, stuck, or still to do.
    const tasks = tasksOf(a, cw)
    // A task marked in progress pulses only while someone is working: the mark is the plan's
    // word, and at rest it must not look like activity.
    const pulse = working.length > 0 ? `<animate attributeName="opacity" values="1;0.35;1" dur="1.4s" repeatCount="indefinite"${phase(1400)}/>` : ''
    const inkOf = { done: C.subtle, working: C.text, stuck: C.red, todo: C.soft } as const
    const headInk = { done: C.green, working: C.amber, stuck: C.red, todo: C.soft } as const
    tasks.columns.forEach((column, c) => {
      const tx = left + c * tasks.colW
      let line = 0
      for (const entry of column) {
        const cx = tx + 5, cy = p.y + HEAD_H + 12 + line * TASK_H
        if (entry.isHead) {
          // A group's line: a small arrow, right when folded and down when unfolded, then its name and count.
          out +=
            (entry.isOpen
              ? `<path d="M${n(cx - 3.5)} ${n(cy - 2)} l7 0 l-3.5 4.6 z" fill="${C.label}"/>`
              : `<path d="M${n(cx - 2)} ${n(cy - 3.5)} l0 7 l4.6 -3.5 z" fill="${C.label}"/>`) +
            `<text x="${n(tx + 16)}" y="${n(p.y + HEAD_H + 15.8 + line * TASK_H)}" font-family="${SANS}" font-size="11" font-weight="600" ` +
            `fill="${headInk[entry.state]}">${esc(entry.lines[0] as string)}</text>`
          if (entry.state === 'working')
            out +=
              `<circle cx="${n(tx + 16 + (entry.lines[0] as string).length * 5.9 + 8)}" cy="${n(cy)}" r="3" fill="${C.amber}">` +
              `${pulse}</circle>`
          line += 1
          continue
        }
        if (entry.state === 'done')
          out += `<path d="M${n(cx - 3.4)} ${n(cy)} l2.4 2.6 l4.4 -5" fill="none" stroke="${C.green}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>`
        else if (entry.state === 'working')
          out +=
            `<circle cx="${n(cx)}" cy="${n(cy)}" r="3.6" fill="${C.amber}">` +
            `${pulse}</circle>`
        else if (entry.state === 'stuck')
          out += `<path d="M${n(cx - 3)} ${n(cy - 3)} l6 6 M${n(cx + 3)} ${n(cy - 3)} l-6 6" fill="none" stroke="${C.red}" stroke-width="1.6" stroke-linecap="round"/>`
        else out += `<circle cx="${n(cx)}" cy="${n(cy)}" r="3.2" fill="none" stroke="${C.label}" stroke-width="1.3"/>`
        for (const words of entry.lines) {
          out +=
            `<text x="${n(tx + 16)}" y="${n(p.y + HEAD_H + 15.8 + line * TASK_H)}" font-family="${SANS}" font-size="11" fill="${inkOf[entry.state]}">` +
            `${esc(words)}</text>`
          line += 1
        }
      }
    })

    // The files last touched here: a filled square for one edited, a hollow one for one only
    // read, how often, and how long ago. The one a call is on right now is amber.
    const files = filesOf(a.path)
    const filesY = p.y + HEAD_H + (tasks.lines > 0 ? tasks.lines * TASK_H + 8 : 0)
    if (files.length > 0) out += `<path d="M${n(left)} ${n(filesY + 3)} H${n(right)}" stroke="${C.track}" stroke-width="1" opacity="0.7"/>`
    files.forEach((f, i) => {
      const cy = filesY + 14 + i * FILE_H
      const ink = f.isActive ? C.amber : f.edits > 0 ? C.blue : C.cyan
      const calls = f.reads + f.edits
      // In words too, so the square needs no key: edited or only read, how often, how long ago.
      // No seconds: an age that changed every few seconds would change the drawing as often.
      const tail = f.isActive ? 'in use now' : [f.edits > 0 ? 'edited' : 'read', calls > 1 ? `×${calls}` : '', now > 0 && f.at > 0 ? (now - f.at < 60_000 ? 'under a minute' : fmtAgo(now - f.at)) : ''].filter(Boolean).join(' · ')
      out +=
        `<rect x="${n(left + 2)}" y="${n(cy - 3)}" width="6" height="6" rx="1.5" fill="${f.edits > 0 || f.isActive ? ink : 'none'}" stroke="${ink}" stroke-width="1.2">` +
        `${f.isActive ? `<animate attributeName="opacity" values="1;0.3;1" dur="0.9s" repeatCount="indefinite"${phase(900)}/>` : ''}</rect>` +
        `<text x="${n(left + 16)}" y="${n(cy + 3.5)}" font-family="${MONO}" font-size="10" font-weight="${f.isActive ? 600 : 500}" ` +
        `fill="${f.isActive ? C.amber : f.edits > 0 ? C.soft : C.subtle}">` +
        `${esc(shorten(f.file.split('/').pop() ?? f.file, Math.max(6, Math.floor((room - 22 - tail.length * 6.1 - 8) / 6.1))))}</text>` +
        (tail
          ? `<text x="${n(right)}" y="${n(cy + 3.5)}" text-anchor="end" font-family="${MONO}" font-size="10" fill="${f.isActive ? C.amber : C.label}">${esc(tail)}</text>`
          : '')
    })

    // Bottom: a row per agent working here now.
    const rowsHere = live.slice(0, MAX_HERE)
    // Under them, what runs in the background on this component.
    const tasksHere = tasksOn(a.path)
    tasksHere.forEach((t, i) => {
      out += taskRow(t, left, p.y + p.h - 13 - AGENT_H / 2 - (tasksHere.length - 1 - i) * AGENT_H, room, '')
    })
    rowsHere.forEach((m, i) => {
      const y = p.y + p.h - 13 - AGENT_H / 2 - (tasksHere.length + rowsHere.length - 1 - i) * AGENT_H
      seat.set(m.id, [left + 5, y])
      out += agentRow(m, left, y, room, live.length > MAX_HERE && i === rowsHere.length - 1 ? `+${live.length - MAX_HERE}` : '')
    })
    // Nothing is left at the foot of a card once nobody works in it: an agent that has ended,
    // or the session between turns, is not on the map.
  }

  // An agent that has just moved: its mark runs along its trail, from the card it left to this one.
  for (const a of agents) {
    const elapsed = now - (a.movedAt ?? 0)
    const d = trails.get(a.id)
    if (!d || !seat.has(a.id) || now <= 0 || !a.movedAt || elapsed < 0 || elapsed >= GLIDE_MS) continue
    const begin = ` begin="-${n(elapsed / 1000)}s"`
    const dur = `${n(GLIDE_MS / 1000)}s`
    out +=
      `<circle r="6" fill="${agentColor(agents, a.id)}" opacity="0">` +
      `<animateMotion path="${d}" dur="${dur}" fill="freeze" calcMode="spline" keyTimes="0;1" keySplines="0.4 0 0.2 1"${begin}/>` +
      `<animate attributeName="opacity" values="0.95;0.95;0" keyTimes="0;0.8;1" dur="${dur}" fill="freeze"${begin}/></circle>`
  }

  const shownH = Math.round(H * zoom)
  const marker = (id: string, color: string) =>
    `<marker id="${id}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" markerHeight="5" orient="auto"><path d="M0 0 10 5 0 10z" fill="${color}"/></marker>`
  const source =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${shown}" height="${shownH}" viewBox="0 0 ${W} ${H}" preserveAspectRatio="xMidYMin meet">` +
    `<defs><pattern id="grid" width="24" height="24" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r="1" fill="${C.track}"/></pattern>` +
    `${marker('arrow', C.track)}${AGENT_COLORS.map((c, k) => marker(`move-${k}`, c)).join('')}</defs>` +
    `<rect width="${W}" height="${H}" fill="url(#grid)" opacity="0.45"/>${out}</svg>`

  const touched = areas.filter(a => stats[a.path]).length
  const doing = working.map(a => `${nameOf(a)}: ${a.doing ?? 'thinking'}${a.area ? ` in ${titleOf(a.area)}` : ''}`)
  const alt =
    `Project map: ${plural(areas.length, 'area')}, ${touched} touched this session` + (doing.length > 0 ? `; ${doing.join('; ')}` : '')
  return { source, alt, width: shown, height: shownH }
}
