import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register, Timer } from 'claude-code'

import type { Area, AreaStat, MapAgent, MapTask, PlanTask } from '../types'
import {
  MAIN, UNPLANNED_AREA, commandArea, describeCall, heatOf, isEdit, isFileTool, lintPlan, matchesGlob, parsePlan, planReport, plural, relPath,
  rehomeAgent, rehomeUnplanned, resolveArea, shorten, toolPath, touchFile,
  TASKS_KEPT, fmtAgo, parseTaskNotification, syncTasks, taskStarted,
} from './core'
import type { ListedTask } from './core'
import { C, HEAT, TASK_GROUPS, agentColor, drawMap } from './draw'

const PANE = 'agent-map'
const TITLE = 'Project map'
const UNPLANNED_TITLE = 'Unplanned files'
// A body cell's width in CSS pixels on the desktop, measured from the app: the map is laid
// out for the panel's real width, and a drawing wider than its slot is shrunk to fit.
const CELL_PX = 9.5
// How often an open panel redraws by itself, so the times on the cards keep counting.
const TICK_MS = 5000

const root = atom({ plugin: 'agent-map', key: 'root' } as const, '')
const areas = atom({ plugin: 'agent-map', key: 'areas' } as const, [])
const stats = atom({ plugin: 'agent-map', key: 'stats' } as const, {})
const agents = atom({ plugin: 'agent-map', key: 'agents' } as const, [])
const tasks = atom({ plugin: 'agent-map', key: 'tasks' } as const, [])
// null until the project is known to have a PLAN.md: the other mods read this too, and draw
// the map's toggle only while it is true or false.
const isOpen = atom({ plugin: 'agent-map', key: 'isOpen' } as const, null)
// Every task group starts folded to one line; the row above the map unfolds them.
const TASKS_FOLDED: { states: PlanTask['state'][]; card: string } = { states: [], card: '' }
const tasksView = atom({ plugin: 'agent-map', key: 'tasksView' } as const, TASKS_FOLDED)
// True where a status-band mod new enough to draw the map's toggle is loaded: this mod then
// adds no row to the band. With an older one, or none, the toggle is drawn here.
const bandCarriesMap = atom({ plugin: 'status-band', key: 'carriesMap' } as const, false)

const mainAgent = (): MapAgent => ({
  id: MAIN, name: 'session', status: 'idle', area: null, doing: null, lastTool: null,
  tools: 0, startedAt: null, endedAt: null,
})
const withMain = (list: MapAgent[] | undefined | null): MapAgent[] => {
  const known = list ?? []
  return known.some(a => a.id === MAIN) ? known : [mainAgent(), ...known]
}

// Changes one agent; a subagent the map has not seen start (it was running before the mod
// loaded) is added as it is first heard from.
const patchAgent = ($: EngineInterface, id: string, change: (a: MapAgent) => MapAgent) =>
  update($, agents, list => {
    const known = withMain(list)
    const seen = known.some(a => a.id === id)
    const all = seen ? known : [...known, { ...mainAgent(), id, name: 'agent', status: 'running' as const }]
    return all.map(a => (a.id === id ? change(a) : a)).slice(-16)
  })

// The map is for a project with a PLAN.md. Without one there is no panel and no toggle; with
// one, the panel comes back the way the person last left it.
const setPlanned = async ($: EngineInterface, planned: boolean) => {
  const cur = (await read($, isOpen)) ?? null
  if (!planned) {
    if (cur === null) return
    await update($, isOpen, () => null)
    await $.ui.close({ id: PANE }).catch(() => undefined)
    return
  }
  if (cur !== null) return
  // The panel never opens by itself: a session starts with it hidden, whatever it was last
  // time, and the toggle or /map shows it.
  await update($, isOpen, () => false)
  await $.ui.close({ id: PANE }).catch(() => undefined)
}

// What /map answers where there is no plan to draw.
const NO_PLAN =
  'No PLAN.md in this project, so there is no map to show. Run /map init and Claude writes one; /map then opens it. ' +
  'The format: one `## Name {#id}` heading per component, with `tech:`, `files:` and `needs:` lines under it and `- [ ]` tasks.'

// Long enough for /map init's own answer to land before the prompt it leads to.
const INIT_DELAY_MS = 150

const FORMAT = [
  'The format the project map reads; anything written another way is not drawn:',
  '- A top line `# <project name>` and a sentence or two on what the project is.',
  '- One `## Name {#id}` heading per component: the id of letters, digits, - and _, unique in the file.',
  '- Under it, each on a line of its own and not as a list item: `tech: ...`, `files: [glob, glob]`, `needs: [id, id]` (the components it depends on, drawn as arrows), `links: [id]` (a looser relation, kept but not drawn), `kind: ...`. Only `files:` is expected every time.',
  '- Globs are relative to the project root, `**` for any depth; the first component to claim a file gets it.',
  '- Tasks directly under the component, at the start of the line: `- [ ] text {#task-id}`, with `[x]` done, `[~]` in progress, `[!]` blocked. Task ids are unique in the file.',
  '- An optional last section `## decisions` of dated one-line decisions.',
].join('\n')

// What `/map init` asks the model for: a first PLAN.md from the project as it is.
const INIT_PROMPT = [
  'Write a PLAN.md at the root of this project so the project map can draw it.',
  '',
  'Read the project first (README, manifests, the folder layout, `git ls-files`), then write the file from what is really there:',
  '- One component per part I would name when describing the project, usually 4 to 12. Not one per folder, and not one for everything.',
  '- Globs that together cover the tracked source files, so little is left unplanned. Leave out generated and vendored files.',
  '- `needs:` from the real dependencies between the components, with no circles.',
  '- Tasks from what the code and its history show: `[x]` for what is built and working, `[ ]` for what is plainly missing or marked TODO. A few per component; do not invent a roadmap.',
  '',
  FORMAT,
  '',
  'After writing it, the map checks the file and reports `PLAN.md:<line>: error` lines with the result; fix every error, and look at each note. Then tell me in a few lines which components you chose and anything you were unsure of.',
].join('\n')

const CONVERT_PROMPT = [
  'This project has a PLAN.md, but the project map cannot draw it: it has no `## Name {#id}` component headings.',
  'Read it and the project, then tell me how you would put it into the format below while keeping what it says. Do not rewrite the file until I agree.',
  '',
  FORMAT,
].join('\n')

// PLAN.md as last read, to tell when something other than the Edit tool has changed it.
let planText = ''

// The plan's components, each with the count of files its globs claim. Git answers for a
// repository (tracked files and new ones it does not ignore); anywhere else the counts stay empty.
const loadMap = async ($: EngineInterface) => {
  const dir = await $.session.root().catch(() => '')
  const before = (await read($, root)) ?? ''
  await update($, root, () => dir)
  // The session moved to another project: what was touched in the old one is not on this map.
  if (before && before !== dir) {
    await update($, areas, () => [])
    await update($, stats, () => ({}))
    await update($, agents, list => withMain(list).map(a => ({ ...a, area: null, trail: [] })))
  }
  // A PLAN.md written to the agenttrail convention names the components: they are the map,
  // each owning the files its globs claim. Without one there is nothing to draw or count.
  const text = dir ? String(await $.fs.read(`${dir}/PLAN.md`).catch(() => '')) : ''
  planText = text
  const plan = parsePlan(text)
  await setPlanned($, plan.length > 0)
  if (plan.length === 0) {
    await update($, areas, () => [])
    return
  }
  const files = (await listFiles($, dir)) ?? []
  const found: Area[] = plan.map(c => ({ ...c, files: files.filter(f => (c.globs ?? []).some(g => matchesGlob(g, f))).length }))
  const unclaimed = files.filter(f => !plan.some(c => (c.globs ?? []).some(g => matchesGlob(g, f)))).length
  if (unclaimed > 0) found.push({ path: UNPLANNED_AREA, title: UNPLANNED_TITLE, files: unclaimed })
  // A file touched while no component claimed it belongs to the one that claims it now. Nothing
  // is written where nothing moves, so a reload that changes nothing redraws nothing.
  const seen = (await read($, stats)) ?? {}
  const rehomed = rehomeUnplanned(seen, plan)
  if (rehomed !== seen) await update($, stats, all => rehomeUnplanned(all ?? {}, plan))
  const isTouched = rehomed[UNPLANNED_AREA] !== undefined
  // So does the agent that touched it, even while other files are still unplanned.
  const isCardGone = !isTouched && unclaimed === 0
  const team = (await read($, agents)) ?? []
  if (team.some(a => rehomeAgent(a, plan, isCardGone) !== a)) await update($, agents, list => withMain(list).map(a => rehomeAgent(a, plan, isCardGone)))
  // The plan's order is the map's. The unplanned card stays while a file a call has touched
  // is still unclaimed, even where the listing counts none.
  await update($, areas, list => [...found, ...(list ?? []).filter(a => a.path === UNPLANNED_AREA && isTouched && !found.some(f => f.path === a.path))])
}

// The project's files as git lists them; null where git cannot say.
const listFiles = async ($: EngineInterface, dir: string) => {
  const git = await $.process
    .run(['git', 'ls-files', '-co', '--exclude-standard'], { cwd: dir, timeoutMs: 8000 })
    .catch(() => null)
  // Claude's own folder (worktrees, launch settings) is not part of the project.
  return git && git.exitCode === 0 ? git.stdout.split('\n').filter(f => f && !f.startsWith('.claude/')) : null
}

// What the map cannot read in the project's PLAN.md, as lines to hand back; '' when it is sound
// or there is no PLAN.md at all.
const checkPlan = async ($: EngineInterface) => {
  const dir = await $.session.root().catch(() => '')
  const text = dir ? String(await $.fs.read(`${dir}/PLAN.md`).catch(() => '')) : ''
  if (!text.trim()) return ''
  return planReport(lintPlan(text, (await listFiles($, dir)) ?? undefined))
}

// A file no component claims, first heard of from a tool call, puts the unplanned card on the map.
const ensureArea = async ($: EngineInterface, area: string) => {
  if (area !== UNPLANNED_AREA || ((await read($, areas)) ?? []).some(a => a.path === area)) return
  await update($, areas, list =>
    (list ?? []).some(a => a.path === area) ? (list ?? []) : [...(list ?? []), { path: area, title: UNPLANNED_TITLE, files: 0 }],
  )
}

const recordTouch = async ($: EngineInterface, area: string, who: string, edited: boolean, at: number, file: string | null) => {
  const name = file === null ? null : (file.split('/').pop() ?? file)
  await update($, stats, all => {
    const cur: AreaStat = (all ?? {})[area] ?? { reads: 0, edits: 0, lastAt: 0, lastBy: who }
    const next: AreaStat = {
      reads: cur.reads + (edited ? 0 : 1),
      edits: cur.edits + (edited ? 1 : 0),
      lastAt: at,
      lastBy: who,
      lastFile: name ?? cur.lastFile,
      lastFileCalls: name === null ? cur.lastFileCalls : name === cur.lastFile ? (cur.lastFileCalls ?? 1) + 1 : 1,
      recent: file === null ? cur.recent : touchFile(cur.recent ?? [], file, edited, at),
    }
    return { ...(all ?? {}), [area]: next }
  })
}

// The engine's own list of this session's subagents, so one that ended in the background is
// marked without a reply.
type Listed = { id: string; description?: string; type?: string; name?: string; status: string }
const ENDED: Record<string, MapAgent['status']> = { completed: 'done', failed: 'failed', killed: 'failed' }
const syncAgents = async ($: EngineInterface) => {
  const listed = (await ($.agent.list() as unknown as Promise<Listed[]>).catch(() => null)) ?? null
  if (!listed) return
  const now = await $.clock.now().catch(() => 0)
  await update($, agents, list =>
    withMain(list).map(a => {
      const l = listed.find(x => x.id === a.id)
      const status = l ? ENDED[l.status] : undefined
      return status && a.status === 'running' ? { ...a, status, doing: null, endedAt: now } : a
    }),
  )
}

const setOpen = async ($: EngineInterface, open: boolean) => {
  await update($, isOpen, () => open)
}
const show = async ($: EngineInterface) => {
  await setOpen($, true)
  const opened = await $.ui.open({ id: PANE, title: TITLE })
  if (!opened.isPlaced) $.ui.toast('Project map: no room for the panel here yet; it opens when there is.')
}
const hide = async ($: EngineInterface) => {
  await setOpen($, false)
  await $.ui.close({ id: PANE }).catch(() => undefined)
}
const toggle = async ($: EngineInterface) => ((await read($, isOpen)) === true ? hide($) : show($))

// A press of the toggle another mod draws: show or hide the panel, where there is a map.
const onMapPress = async <E, R>($: EngineInterface, e: E, next: (e: E) => Promise<R>) => {
  const set = await next(e)
  if (((await read($, isOpen)) ?? null) !== null) await toggle($).catch(() => undefined)
  return set
}

// What the model is told in every project with a PLAN.md, as a section of its system prompt:
// the plan comes before the work, so the map shows the work while it happens.
const PLAN_FIRST = {
  id: 'agent-map:plan-first',
  scope: 'session',
  text: [
    '# PLAN.md and the project map',
    'This project has a PLAN.md at its root, and the person is watching it drawn live as a project map: its components as cards, their tasks, and which card you are working in.',
    'When a prompt asks for work (anything that changes files), do this before the first change:',
    '1. Put the work into PLAN.md: its steps as `- [ ] text {#id}` tasks under the component whose `files:` globs cover the files you will change; add a component, with its globs, only where none fits.',
    '2. Mark the task you are starting `- [~]`.',
    'Then, as you go: mark a task `- [x]` the moment it is done and checked, and mark the next one `- [~]` before starting it, one at a time.',
    'Before your turn ends, leave no task marked `- [~]` unless its work really continues: finished ones become `- [x]`, the rest go back to `- [ ]`.',
    'A question, an explanation or a read-only look needs no entry in PLAN.md.',
  ].join('\n'),
} as const
const PLAN_REMINDER =
  'You changed a file of this project while no task in PLAN.md is marked in progress, so the project map shows nothing being worked on. ' +
  'Before the next change: add this work to PLAN.md as a task under the right component if it is not there, and mark it `- [~]`. Mark it `- [x]` when it is done.'

export const register: Register = on => {
  let ticker: Timer | null = null
  // The reminder is given once a turn at most.
  let isReminded = false

  on('prompt.compose', async ($, e, next) => {
    const composed = await next(e)
    if (((await read($, isOpen).catch(() => null)) ?? null) === null) return composed
    return { ...composed, sections: [...composed.sections.filter(x => x.id !== PLAN_FIRST.id), PLAN_FIRST] }
  })

  on('session.start', async ($, e, next) => {
    await $.command.register({ name: 'map', description: 'Show or hide the project map panel; `/map refresh` reads the project again, `/map init` writes PLAN.md, `/map check` checks it', argumentHint: '[refresh|init|check]' })
    await update($, agents, list => withMain(list))
    // Not awaited: listing a large project must not hold up the session's start.
    // It also settles whether there is a map here at all; the panel itself stays hidden.
    void loadMap($).catch(() => undefined)
    try {
      ticker?.cancel()
      let beat = 0
      ticker = $.clock.every(TICK_MS, () => {
        beat += 1
        // While someone works the map is redrawn every beat; at rest only the ages on it change,
        // so every sixth beat is enough. Each redraw replaces the drawing, and fewer of them
        // leave a scrolled map alone.
        void Promise.all([read($, isOpen), read($, agents)])
          .then(([open, team]) => {
            const isWorking = (team ?? []).some(a => a.status === 'running' || a.doing !== null)
            if (open === true && (isWorking || beat % 6 === 0)) $.ui.invalidate('ui.render')
          })
          .catch(() => undefined)
      })
    } catch {
      // A host without timers: the panel still redraws on every event it sees.
    }
    return next(e)
  })

  on('command.run', { command: 'map' }, async ($, e) => {
    // `/map check`: what the map cannot read in PLAN.md, without touching the panel.
    if (String(e.args ?? '').trim() === 'check') {
      await loadMap($).catch(() => undefined)
      if (((await read($, isOpen)) ?? null) === null && !(await checkPlan($).catch(() => ''))) return { text: NO_PLAN }
      return { text: (await checkPlan($).catch(() => '')) || 'PLAN.md is sound: the map reads all of it.' }
    }
    // `/map refresh`: PLAN.md, the project's files and the session's agents read again, and the
    // map drawn afresh, shown or hidden as it was.
    if (String(e.args ?? '').trim() === 'refresh') {
      await loadMap($).catch(() => undefined)
      await syncAgents($).catch(() => undefined)
      if (((await read($, isOpen)) ?? null) === null) return { text: NO_PLAN }
      $.ui.invalidate('ui.render')
      const cards = ((await read($, areas)) ?? []).filter(a => a.path !== UNPLANNED_AREA).length
      const report = await checkPlan($).catch(() => '')
      const problems = report ? report.split('\n').filter(l => /: error:/.test(l)).length : 0
      return {
        text: `Project map read again: ${cards} ${cards === 1 ? 'component' : 'components'}.${problems > 0 ? ` PLAN.md has ${problems} ${problems === 1 ? 'error' : 'errors'} the map cannot read; /map check lists them.` : ''}`,
      }
    }
    // `/map init`: have the model write the plan, where there is none the map can draw.
    if (String(e.args ?? '').trim() === 'init') {
      await loadMap($).catch(() => undefined)
      if (((await read($, isOpen)) ?? null) !== null) {
        return { text: 'This project already has a PLAN.md the map can draw, so /map init leaves it alone. /map shows it; /map check checks it.' }
      }
      const dir = await $.session.root().catch(() => '')
      const existing = dir ? String(await $.fs.read(`${dir}/PLAN.md`).catch(() => '')) : ''
      // From a timer, not from here: the engine refuses a prompt submitted by the command's own
      // hook, as it would wait on the turn this hook is holding.
      const text = existing.trim() ? CONVERT_PROMPT : INIT_PROMPT
      $.clock.after(INIT_DELAY_MS, () => void $.prompt.submit({ text, asUser: true }).catch(() => undefined))
      return {
        text: existing.trim()
          ? 'There is a PLAN.md here, in a format the map cannot draw. Asked Claude to propose a conversion; nothing is rewritten until you agree.'
          : 'Asked Claude to write PLAN.md from the project. /map opens the map once it is there.',
      }
    }
    // The plan may have been written since the project was last read.
    if (((await read($, isOpen)) ?? null) === null) await loadMap($).catch(() => undefined)
    if (((await read($, isOpen)) ?? null) === null) return { text: NO_PLAN }
    await toggle($)
    return { text: (await read($, isOpen)) === true ? 'Project map shown.' : 'Project map hidden. /map shows it again.' }
  })

  // The status band and the session's rule draw the map's toggle and count its presses. A press
  // toggles the panel here, silently: nothing is typed into the prompt or the transcript.
  on('state.set', { plugin: 'status-band', key: 'mapPress' }, onMapPress)
  on('state.set', { plugin: 'session-tint', key: 'mapPress' }, onMapPress)

  // Closed from the panel's own mark or key: remember it as hidden.
  on('ui.close', async ($, e, next) => {
    // Not when the mod itself closed it for want of a plan: that is not the person's choice.
    if (e.id === PANE && (await read($, isOpen)) === true) await setOpen($, false).catch(() => undefined)
    return next(e)
  })

  on('prompt.submit', async ($, e, next) => {
    isReminded = false
    const now = await $.clock.now().catch(() => 0)
    // Read the project again, not awaited: the session may have moved to another folder, and
    // PLAN.md or the file tree may have changed since the last prompt.
    void loadMap($).catch(() => undefined)
    // A background task's notification arrives as a prompt: it says which task ended and how.
    // Any other prompt clears the tasks that have ended; the ones still running stay.
    const isNotice = (e as unknown as { origin?: { kind?: string } }).origin?.kind === 'task-notification'
    const notice = isNotice ? parseTaskNotification(e.text) : null
    if (notice && notice.status !== 'running') {
      await update($, tasks, list => (list ?? []).map(t => (t.id === notice.id && t.status === 'running' ? { ...t, status: notice.status, endedAt: now } : t))).catch(() => undefined)
    } else if (!isNotice) {
      await update($, tasks, list => (list ?? []).filter(t => t.status === 'running')).catch(() => undefined)
    }
    // A new prompt clears the finished subagents; ones still running stay.
    await update($, agents, list =>
      withMain(list)
        .filter(a => a.id === MAIN || a.status === 'running')
        .map(a => (a.id === MAIN ? { ...a, status: 'running' as const, loose: true, startedAt: now, endedAt: null } : a)),
    ).catch(() => undefined)
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    await syncAgents($).catch(() => undefined)
    return next(e)
  })

  on('classic.Stop', async ($, e, next) => {
    await syncAgents($).catch(() => undefined)
    // The engine says what is still running in the background each time the session stops:
    // a task the map did not see start is added, and one that is gone from the list has ended.
    try {
      const listed = (e as unknown as { background_tasks?: ListedTask[] }).background_tasks
      if (Array.isArray(listed)) {
        const dir = (await read($, root)) ?? ''
        const plan = (await read($, areas)) ?? []
        const now = await $.clock.now().catch(() => 0)
        await update($, tasks, list => syncTasks(list ?? [], listed, now, command => commandArea(command, dir, plan)))
      }
    } catch {
      // The map keeps what it had.
    }
    return next(e)
  })

  on('agent.spawn', async ($, e, next) => {
    const started = await next(e)
    if (started.deny !== undefined || !started.agentId) return started
    const agent: MapAgent = {
      id: started.agentId,
      name: shorten(e.name ?? e.description ?? e.subagentType, 28),
      status: 'running',
      area: null,
      doing: null,
      lastTool: null,
      tools: 0,
      startedAt: await $.clock.now().catch(() => null),
      endedAt: null,
    }
    await update($, agents, list => [...withMain(list).filter(a => a.id !== agent.id), agent].slice(-16)).catch(() => undefined)
    return started
  })

  on('tool.call', async ($, e, next) => {
    const who = e.agentId ?? MAIN
    const tool = String(e.tool)
    const args = e as unknown as Record<string, unknown>
    // Nothing the map does may hold up or fail a tool call.
    let area: string | null = null
    // The one file the call names, relative to the project; null for a search or a command.
    let file: string | null = null
    try {
      const path = toolPath(tool, args)
      const rel = path ? relPath((await read($, root)) ?? '', path) : null
      area = rel === null ? null : resolveArea(rel, (await read($, areas)) ?? [])
      // A shell command names no one file, but often a path: it lights the component that path is in.
      if (area === null && (tool === 'Bash' || tool === 'PowerShell' || tool === 'Monitor') && typeof args.command === 'string') {
        area = commandArea(args.command, (await read($, root)) ?? '', (await read($, areas)) ?? [])
      }
      file = rel && isFileTool(tool) ? rel : null
      if (area !== null) await ensureArea($, area)
      const doing = describeCall(tool, args)
      const stop = area
      const inFlight = file
      const at = await $.clock.now().catch(() => 0)
      await patchAgent($, who, a => {
        const trail = a.trail ?? []
        const moved = stop !== null && trail[trail.length - 1] !== stop
        return {
          ...a, status: 'running', doing, lastTool: tool, file: inFlight, loose: stop === null, area: stop ?? a.area,
          trail: moved ? [...trail, stop].slice(-8) : trail,
          // Only a move from another card glides; the first stop has nowhere to come from.
          movedAt: moved && trail.length > 0 ? at : a.movedAt,
        }
      })
    } catch {
      // The map just misses this call.
    }
    const ran = await next(e)
    try {
      const ok = ran.deny === undefined && ran.isError !== true
      if (area !== null && ok) await recordTouch($, area, who, isEdit(tool), await $.clock.now(), file)
      await patchAgent($, who, a => ({ ...a, doing: null, file: null, tools: a.tools + 1 }))
      // The call left something running in the background: it is on the map from now until it ends.
      const left = ok ? taskStarted(tool, args, (ran as { result?: unknown }).result) : null
      if (left) {
        const at = await $.clock.now().catch(() => 0)
        const task: MapTask = { ...left, area: area === UNPLANNED_AREA ? null : area, status: 'running', startedAt: at, endedAt: null }
        await update($, tasks, list => [...(list ?? []).filter(t => t.id !== task.id), task].slice(-TASKS_KEPT))
      }
      if (tool === 'TaskStop' && ok) {
        const id = typeof args.task_id === 'string' ? args.task_id : typeof args.shell_id === 'string' ? args.shell_id : ''
        const at = await $.clock.now().catch(() => 0)
        if (id) await update($, tasks, list => (list ?? []).map(t => (t.id === id && t.status === 'running' ? { ...t, status: 'stopped' as const, endedAt: at } : t)))
      }
      // The plan itself was edited, a task ticked say: show it now, not at the next prompt,
      // and tell the model, after the tool's result, what in it the map cannot read.
      if (file === 'PLAN.md' && ok && isEdit(tool)) {
        await loadMap($)
        const report = await checkPlan($)
        if (report && ran.deny === undefined) {
          const note = `The project map cannot read parts of PLAN.md as it now stands. Fix each error; a note needs a look, not always a change.\n${report}`
          return { ...ran, context: [...(ran.context ?? []), note] }
        }
      }
      // A shell command can change PLAN.md too (a script, sed, git checkout): after each one
      // the file is compared with what was last read, and read again when it differs.
      if (tool === 'Bash' || tool === 'PowerShell') {
        const dir = (await read($, root)) ?? ''
        const now = dir ? String(await $.fs.read(`${dir}/PLAN.md`).catch(() => '')) : ''
        if (now !== planText) {
          await loadMap($)
          const report = await checkPlan($)
          if (report && ran.deny === undefined) {
            const note = `The project map cannot read parts of PLAN.md as it now stands. Fix each error; a note needs a look, not always a change.\n${report}`
            return { ...ran, context: [...(ran.context ?? []), note] }
          }
        }
      }
      // A file changed with nothing in the plan marked in progress: the map would show no work.
      // The session is told once, after the edit's result.
      if (ok && ran.deny === undefined && isEdit(tool) && file !== null && file !== 'PLAN.md' && who === MAIN && !isReminded) {
        const plan = (await read($, areas)) ?? []
        if (plan.some(a => a.tasks) && !plan.some(a => (a.tasks?.working ?? 0) > 0)) {
          isReminded = true
          return { ...ran, context: [...(ran.context ?? []), PLAN_REMINDER] }
        }
      }
    } catch {
      // As above.
    }
    return ran
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    const now = await $.clock.now().catch(() => 0)
    if (e.agentId) {
      const status = e.reason === 'answer' ? 'done' : 'failed'
      await patchAgent($, e.agentId, a => ({ ...a, status, doing: null, endedAt: now })).catch(() => undefined)
    } else {
      await patchAgent($, MAIN, a => ({ ...a, status: 'idle', doing: null, endedAt: now })).catch(() => undefined)
    }
    return done
  })

  // Without a status band that carries it, the toggle is one short word on a row of its own.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    if ((await read($, bandCarriesMap).catch(() => false)) === true) return next(e)
    if (((await read($, isOpen)) ?? null) === null) return next(e)
    const { Box, Button } = $.ui.resolve(e)
    // Whatever another mod draws in the band goes on top of this row.
    const beneath = await next(e)
    const below = beneath.type === 'engine' ? null : beneath
    const open = (await read($, isOpen)) === true
    return (
      <Box flexDirection="column" width="100%">
        {below}
        <Box width="100%" justifyContent="flex-end">
          <Button key="map" plain label={open ? 'hide map' : 'map'} onPress={() => toggle($)} />
        </Box>
      </Box>
    )
  })


  // The panel is the map and nothing else. The desktop draws it as cards joined by arrows, each
  // card listing its tasks; the terminal has no vector element and lists the same as rows.
  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const Svg = e.surface === 'terminal' ? undefined : $.ui.resolve(e).Svg
    const map: Area[] = (await read($, areas)) ?? []
    const folds = (await read($, tasksView)) ?? TASKS_FOLDED
    const seen: Record<string, AreaStat> = (await read($, stats)) ?? {}
    const team = withMain(await read($, agents))
    const background: MapTask[] = (await read($, tasks)) ?? []
    const now = await $.clock.now().catch(() => 0)
    const cells = e.props.bodyColumns ?? 80
    if (map.length === 0) return <Text color={C.label}>PLAN.md names no components yet.</Text>
    // The one row of controls: the drawing cannot be pressed, so what unfolds a card's task groups
    // sits above it. A status is unfolded on every card.
    // Tasks in progress are always listed, so they have no toggle.
    // Only the statuses the plan has tasks in are offered: a toggle for an empty group does nothing.
    const offered = TASK_GROUPS.filter(([state]) => state !== 'working' && map.some(a => (a.taskList ?? []).some(t => t.state === state)))
    const controls = offered.length === 0 ? null : (
      <Box key="folds" width="100%" flexWrap="wrap" alignItems="center" columnGap={2} rowGap={1}>
        <Box flexShrink={0}><Text color={C.label}>TASKS</Text></Box>
        {offered.map(([state, label]) => {
          const isShown = folds.states.includes(state)
          return (
            <Box key={`fold-${state}`} flexShrink={0}>
              <Button
                key={`fold:${state}`}
                plain
                dimColor={!isShown}
                label={`${isShown ? '▾' : '▸'} ${label}`}
                onPress={() => update($, tasksView, old => ({ ...(old ?? TASKS_FOLDED), states: isShown ? (old ?? TASKS_FOLDED).states.filter(x => x !== state) : [...(old ?? TASKS_FOLDED).states, state] }))}
              />
            </Box>
          )
        })}
      </Box>
    )
    const isUnfolded = (a: Area, state: PlanTask['state']) => state === 'working' || folds.card === '*' || folds.card === a.path || folds.states.includes(state)
    if (Svg) {
      // No size is given to the image: a fixed height stayed when a narrow panel shrank the
      // drawing's width, which left empty space above the first card.
      const drawing = drawMap({ areas: map, stats: seen, agents: team, tasks: background, width: cells * CELL_PX - 8, now, unfolded: folds })
      return (
        <Box flexDirection="column" width="100%" rowGap={1}>
          {controls}
          <Box width="100%">
            <Svg source={drawing.source} alt={drawing.alt} />
          </Box>
        </Box>
      )
    }

    // Web app   4/6 tasks   2 edits · 5 reads   ● session ● Explore
    //   ✓ Public repo and readme
    //   ◐ Filmed real-session demo video
    const wide = cells >= 84
    const TASK = { done: ['✓', C.green], working: ['◐', C.amber], stuck: ['✗', C.red], todo: ['○', C.label] } as const
    const areaRows = (a: Area) => {
      const here = team.filter(t => t.area === a.path && (t.status === 'running' || t.doing !== null))
      const stat = seen[a.path]
      const heat = heatOf(stat, here.length > 0)
      const progress = a.tasks && a.tasks.total > 0 ? `${a.tasks.done}/${a.tasks.total} tasks` : a.files > 0 ? plural(a.files, 'file') : ''
      const activity = !stat
        ? ''
        : [stat.edits > 0 ? plural(stat.edits, 'edit') : '', stat.reads > 0 ? plural(stat.reads, 'read') : ''].filter(Boolean).join(' · ')
      return (
        <Box key={`area-${a.path}`} flexDirection="column" width="100%">
          <Box width="100%">
            <Box width={wide ? '34%' : '44%'} paddingRight={2}>
              <Text color={HEAT[heat]} bold={heat === 'live'} wrap="truncate">{a.title ?? a.path}</Text>
            </Box>
            {wide ? (
              <Box width="14%" paddingRight={2}>
                <Text color={C.label} wrap="truncate">{progress}</Text>
              </Box>
            ) : null}
            <Box width={wide ? '22%' : '26%'} paddingRight={2}>
              <Text color={heat === 'cold' ? C.label : C.subtle} wrap="truncate">{activity || (wide ? '' : progress)}</Text>
            </Box>
            <Box width="30%">
              {here.map(t => (
                <Box key={`here-${t.id}`} paddingRight={1}>
                  <Text color={agentColor(team, t.id)} wrap="truncate">{`● ${shorten(t.name, 14)}`}</Text>
                </Box>
              ))}
            </Box>
          </Box>
          {TASK_GROUPS.flatMap(([state, label]) => {
            const mine = (a.taskList ?? []).filter(t => t.state === state)
            if (mine.length === 0) return []
            const isShown = isUnfolded(a, state)
            return [
              <Box key={`group-${a.path}-${state}`} width="100%" paddingLeft={2}>
                <Text color={TASK[state][1]}>{`${isShown ? '▾' : '▸'} ${label} · ${mine.length}`}</Text>
              </Box>,
              ...(isShown
                ? mine.map((t, i) => (
                    <Box key={`task-${a.path}-${state}-${i}`} width="100%" paddingLeft={4}>
                      <Text color={TASK[t.state][1]}>{`${TASK[t.state][0]} `}</Text>
                      <Text color={t.state === 'done' ? C.label : t.state === 'working' ? C.text : C.subtle} wrap="truncate">{t.text}</Text>
                    </Box>
                  ))
                : []),
            ]
          })}
        </Box>
      )
    }
    // ▢ shell  npm run dev  2 min  in Dashboard
    const TASK_COLOR = { running: C.cyan, done: C.green, failed: C.red, stopped: C.label } as const
    const taskRows = background.map(t => {
      const ran = t.startedAt === null ? '' : fmtAgo((t.endedAt ?? now) - t.startedAt)
      const where = map.find(a => a.path === t.area)
      return (
        <Box key={`bg-${t.id}`} width="100%">
          <Box flexShrink={0} paddingRight={2}><Text color={TASK_COLOR[t.status]}>{`▢ ${t.kind}`}</Text></Box>
          <Box flexGrow={1} flexShrink={1} minWidth={0} paddingRight={2}><Text color={t.status === 'running' ? C.text : C.subtle} wrap="truncate">{t.what}</Text></Box>
          <Box flexShrink={0}><Text color={C.label}>{[t.status === 'running' ? ran : `${t.status}${ran ? ` after ${ran}` : ''}`, where ? `in ${where.title ?? where.path}` : ''].filter(Boolean).join(' · ')}</Text></Box>
        </Box>
      )
    })
    return (
      <Box flexDirection="column" width="100%">
        {controls}
        {taskRows}
        {map.map(areaRows)}
      </Box>
    )
  })
}
