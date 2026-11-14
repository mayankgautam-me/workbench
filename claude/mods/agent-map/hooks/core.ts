// Pure logic for the project map. Nothing here touches `$`.

import type { Area, AreaStat, FileTouch, PlanTask, MapTask } from '../types'

/** The session itself, shown on the map beside its subagents. */
export const MAIN = 'main'
/** A tool's path made relative to the project root; null when it lies outside the project. */
export const relPath = (root: string, path: string) => {
  if (!path.startsWith('/')) return path.replace(/^\.\//, '')
  if (!root) return null
  const base = root.endsWith('/') ? root : `${root}/`
  if (path === root) return ''
  return path.startsWith(base) ? path.slice(base.length) : null
}

/** Files no PLAN.md component claims. */
export const UNPLANNED_AREA = '(unplanned)'

const globToRegex = (glob: string) => {
  let out = ''
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i] as string
    if (c === '*' && glob[i + 1] === '*') {
      if (glob[i + 2] === '/') { out += '(?:.*/)?'; i += 2 } else { out += '.*'; i += 1 }
    } else if (c === '*') out += '[^/]*'
    else if (c === '?') out += '[^/]'
    else out += c.replace(/[.+^${}()|[\]\\]/g, '\\$&')
  }
  return new RegExp(`^${out}$`)
}
/** Whether a project-relative path matches a glob (`**`, `*`, `?`); a bare folder matches all beneath it. */
export const matchesGlob = (glob: string, rel: string) => {
  const g = glob.trim().replace(/^\.\//, '')
  if (!g) return false
  if (!/[*?]/.test(g)) return rel === g || rel.startsWith(g.endsWith('/') ? g : `${g}/`)
  return globToRegex(g).test(rel)
}

const listOf = (value: string) =>
  value.replace(/^\[|\]$/g, '').split(',').map(x => x.trim().replace(/^["'`]|["'`]$/g, '')).filter(Boolean)

/**
 * The components of a PLAN.md written to the agenttrail convention: `## Name {#id}` with
 * `tech:`, `files:`, `needs:`, `links:` and `kind:` lines and `- [ ]` / `[~]` / `[x]` / `[!]` tasks.
 */
export const parsePlan = (text: string): Area[] => {
  const found: Area[] = []
  let cur: Area | null = null
  for (const raw of text.split('\n')) {
    const head = /^##\s+(.+?)\s*\{#([\w-]+)\}\s*$/.exec(raw)
    if (head) {
      cur = {
        path: head[2] as string, title: (head[1] as string).trim(), files: 0,
        tasks: { done: 0, working: 0, stuck: 0, total: 0 }, taskList: [],
      }
      found.push(cur)
      continue
    }
    if (/^#{1,2}\s/.test(raw)) { cur = null; continue }
    if (!cur) continue
    const field = /^(tech|files|needs|links|kind):\s*(.+)$/.exec(raw.trim())
    if (field && !/^\s*-/.test(raw)) {
      const [, key, value] = field as unknown as [string, string, string]
      if (key === 'tech') cur.tech = value.trim()
      else if (key === 'kind') cur.kind = value.trim()
      else if (key === 'files') cur.globs = listOf(value)
      else if (key === 'needs') cur.needs = listOf(value)
      else cur.links = listOf(value)
      continue
    }
    const task = /^-\s+\[([ x~!])\]\s*(.*)$/i.exec(raw)
    if (task && cur.tasks) {
      const mark = (task[1] as string).toLowerCase()
      cur.tasks.total += 1
      if (mark === 'x') cur.tasks.done += 1
      else if (mark === '~') cur.tasks.working += 1
      else if (mark === '!') cur.tasks.stuck += 1
      const state: PlanTask['state'] = mark === 'x' ? 'done' : mark === '~' ? 'working' : mark === '!' ? 'stuck' : 'todo'
      const text = (task[2] as string).replace(/\s*\{#[\w-]+\}\s*$/, '').trim()
      if (text && (cur.taskList ?? []).length < 250) (cur.taskList ??= []).push({ text, state })
    }
  }
  return found
}

/** A card's recent files with one more touch: that file first, its counts kept, four at most. */
export const touchFile = (recent: readonly FileTouch[], file: string, edited: boolean, at: number): FileTouch[] => {
  const was = recent.find(r => r.file === file)
  const now: FileTouch = { file, reads: (was?.reads ?? 0) + (edited ? 0 : 1), edits: (was?.edits ?? 0) + (edited ? 1 : 0), at }
  return [now, ...recent.filter(r => r.file !== file)].slice(0, 4)
}

/** One thing wrong with a PLAN.md: an error keeps something off the map, a note is worth a look. */
export type PlanProblem = { line: number; level: 'error' | 'note'; text: string }

const NEAR_FIELDS: Record<string, string> = {
  file: 'files', glob: 'files', globs: 'files', paths: 'files', need: 'needs', depends: 'needs', deps: 'needs',
  requires: 'needs', link: 'links', related: 'links', stack: 'tech', technology: 'tech', type: 'kind',
}

/**
 * What the map cannot read in a PLAN.md, line by line. It walks the file the way `parsePlan`
 * does, so whatever it passes is drawn. `files` is the project's file list where one is known:
 * with it, a glob that claims nothing is noted.
 */
export const lintPlan = (text: string, files?: readonly string[]): PlanProblem[] => {
  const out: PlanProblem[] = []
  const add = (line: number, level: PlanProblem['level'], msg: string) => void out.push({ line, level, text: msg })
  type Seen = { id: string; line: number; fields: Set<string>; globs: string[] | null; refs: { key: string; id: string; line: number }[] }
  const comps: Seen[] = []
  const taskIds = new Map<string, number>()
  let cur: Seen | null = null
  // Under a `##` heading with no id (`## decisions`), list items are prose, not lost tasks.
  let loose = false
  text.split('\n').forEach((raw, i) => {
    const line = i + 1
    const head = /^##\s+(.+?)\s*\{#([\w-]+)\}\s*$/.exec(raw)
    if (head) {
      const id = head[2] as string
      const first = comps.find(c => c.id === id)
      if (first) add(line, 'error', `component id {#${id}} is already used on line ${first.line}; ids must be unique`)
      cur = { id, line, fields: new Set(), globs: null, refs: [] }
      comps.push(cur)
      loose = false
      return
    }
    if (/^#{1,2}\s/.test(raw)) {
      if (/^##\s/.test(raw) && raw.includes('{')) add(line, 'error', 'heading has a malformed id; write `## Name {#id}` with only letters, digits, - and _ in the id, and nothing after it')
      cur = null
      loose = /^##\s/.test(raw) && !raw.includes('{')
      return
    }
    const trimmed = raw.trim()
    const asItem = /^[-*+]\s+(tech|files|needs|links|kind)\s*:/.exec(trimmed)
    if (asItem) return add(line, 'error', `\`${asItem[1]}:\` is written as a list item, so it is not read; put it on a line of its own without the dash`)
    const near = /^([A-Za-z]+)\s*:/.exec(trimmed)
    if (cur && near && NEAR_FIELDS[(near[1] as string).toLowerCase()]) {
      return add(line, 'error', `\`${near[1]}:\` is not a field the map reads; did you mean \`${NEAR_FIELDS[(near[1] as string).toLowerCase()]}:\`?`)
    }
    const field = /^(tech|files|needs|links|kind):\s*(.*)$/.exec(trimmed)
    if (field) {
      const key = field[1] as string
      const value = field[2] as string
      if (!cur) return void (loose || add(line, 'error', `\`${key}:\` is not under a \`## Name {#id}\` heading, so it belongs to no component`))
      if (cur.fields.has(key)) add(line, 'error', `component {#${cur.id}} has \`${key}:\` twice; only the last one counts`)
      cur.fields.add(key)
      const items = listOf(value)
      if (!value.trim() || (key !== 'tech' && key !== 'kind' && items.length === 0)) return add(line, 'error', `\`${key}:\` is empty`)
      if (key === 'files') {
        cur.globs = items
        for (const g of items) {
          if (g.startsWith('/') || g.startsWith('../') || g.includes('/../')) add(line, 'error', `glob \`${g}\` must be relative to the project root, with no leading / and no ..`)
        }
      } else if (key === 'needs' || key === 'links') {
        for (const id of items) cur.refs.push({ key, id, line })
      }
      return
    }
    const item = /^(\s*)([-*+])\s*\[([^\]]*)\]/.exec(raw)
    if (!item) return
    const isTask = /^-\s+\[([ x~!])\]\s*(.*)$/i.exec(raw)
    if (!isTask) {
      if (loose && !cur) return
      const why = item[1] ? 'it is indented' : item[2] !== '-' ? 'it does not start with `- `' : !/^-\s/.test(raw) ? 'there is no space after the dash' : `\`[${item[3]}]\` is not a mark`
      return add(line, 'error', `task is not read because ${why}; write \`- [ ] text\` at the start of the line, the mark one of [ ] [~] [x] [!]`)
    }
    if (!cur) return void (loose || add(line, 'error', 'task is not under a `## Name {#id}` heading, so it belongs to no component'))
    const body = isTask[2] as string
    if (!body.replace(/\s*\{#[\w-]+\}\s*$/, '').trim()) add(line, 'error', 'task has no text')
    const tid = /\{#([\w-]+)\}\s*$/.exec(body)
    if (tid) {
      const first = taskIds.get(tid[1] as string)
      if (first !== undefined) add(line, 'error', `task id {#${tid[1]}} is already used on line ${first}`)
      else taskIds.set(tid[1] as string, line)
    }
  })
  if (comps.length === 0) {
    add(1, 'error', 'no component found: the map needs at least one `## Name {#id}` heading')
    return out
  }
  const ids = new Set(comps.map(c => c.id))
  for (const c of comps) {
    for (const r of c.refs) {
      if (r.id === c.id) add(r.line, 'error', `component {#${c.id}} names itself in \`${r.key}:\``)
      else if (!ids.has(r.id)) add(r.line, 'error', `\`${r.key}:\` names {#${r.id}}, and no component has that id`)
    }
    if (c.globs === null) add(c.line, 'note', `component {#${c.id}} has no \`files:\` line, so work never shows on its card`)
    else if (files) {
      for (const g of c.globs) {
        if (!files.some(f => matchesGlob(g, f))) add(c.line, 'note', `glob \`${g}\` of {#${c.id}} matches no file in the project; fine for work not started, stale if the files moved`)
      }
    }
  }
  // A cycle of needs has no top and bottom to draw.
  const needs = new Map(comps.map(c => [c.id, c.refs.filter(r => r.key === 'needs' && ids.has(r.id) && r.id !== c.id).map(r => r.id)]))
  const state = new Map<string, 1 | 2>()
  const walk = (id: string, path: string[]): string[] | null => {
    if (state.get(id) === 2) return null
    if (state.get(id) === 1) return [...path.slice(path.indexOf(id)), id]
    state.set(id, 1)
    for (const n of needs.get(id) ?? []) {
      const loop = walk(n, [...path, id])
      if (loop) return loop
    }
    state.set(id, 2)
    return null
  }
  for (const c of comps) {
    const loop = walk(c.id, [])
    if (loop) {
      add(c.line, 'error', `\`needs:\` goes in a circle: ${loop.join(' → ')}`)
      break
    }
  }
  return out.sort((a, b) => a.line - b.line)
}

/** The problems as the lines Claude or the person reads; empty when there are none. */
export const planReport = (problems: readonly PlanProblem[]) =>
  problems.map(p => `PLAN.md:${p.line}: ${p.level === 'error' ? 'error' : 'note'}: ${p.text}`).join('\n')

/** The component a path belongs to: the one whose globs claim it, else the unplanned card; null without a plan. */
export const resolveArea = (rel: string, areas: readonly Area[]) => {
  const planned = areas.filter(a => a.globs !== undefined || a.title !== undefined)
  if (planned.length === 0) return null
  return planned.find(a => (a.globs ?? []).some(g => matchesGlob(g, rel)))?.path ?? UNPLANNED_AREA
}

/**
 * The session's touches after PLAN.md changed: a file recorded on the unplanned card that a
 * component now claims moves to that component, and an unplanned entry left with no file is
 * dropped, so the card can go once nothing is unplanned.
 */
export const rehomeUnplanned = (stats: Readonly<Record<string, AreaStat>>, areas: readonly Area[]): Record<string, AreaStat> => {
  const loose = stats[UNPLANNED_AREA]
  // Nothing to move: the same object goes back, so the caller can tell and write nothing.
  if (!loose?.recent?.length) return stats as Record<string, AreaStat>
  const out: Record<string, AreaStat> = { ...stats }
  const kept: FileTouch[] = []
  let reads = loose.reads
  let edits = loose.edits
  for (const t of loose.recent) {
    const to = resolveArea(t.file, areas)
    if (to === null || to === UNPLANNED_AREA) { kept.push(t); continue }
    reads -= t.reads
    edits -= t.edits
    const cur: AreaStat = out[to] ?? { reads: 0, edits: 0, lastAt: 0, lastBy: loose.lastBy }
    const was = cur.recent?.find(r => r.file === t.file)
    const merged: FileTouch = { file: t.file, reads: t.reads + (was?.reads ?? 0), edits: t.edits + (was?.edits ?? 0), at: Math.max(t.at, was?.at ?? 0) }
    const isLatest = t.at > cur.lastAt
    out[to] = {
      ...cur,
      reads: cur.reads + t.reads,
      edits: cur.edits + t.edits,
      lastAt: Math.max(cur.lastAt, t.at),
      lastBy: isLatest ? loose.lastBy : cur.lastBy,
      lastFile: isLatest ? (t.file.split('/').pop() ?? t.file) : cur.lastFile,
      lastFileCalls: isLatest ? 1 : cur.lastFileCalls,
      recent: [merged, ...(cur.recent ?? []).filter(r => r.file !== t.file)].sort((a, b) => b.at - a.at).slice(0, 4),
    }
  }
  if (kept.length === loose.recent.length) return stats as Record<string, AreaStat>
  const newest = kept[0]
  if (!newest) {
    delete out[UNPLANNED_AREA]
    return out
  }
  out[UNPLANNED_AREA] = {
    ...loose,
    reads: Math.max(0, reads),
    edits: Math.max(0, edits),
    lastAt: newest.at,
    lastFile: newest.file.split('/').pop() ?? newest.file,
    lastFileCalls: 1,
    recent: kept,
  }
  return out
}

/**
 * An agent after PLAN.md changed. One standing on the unplanned card whose file a component now
 * claims moves to that component, whatever else is still unplanned; once the card itself is
 * gone, nobody is left on it or shown as having passed through it. The same object goes back
 * where nothing changes.
 */
export const rehomeAgent = <A extends { area?: string | null; file?: string | null; trail?: string[] }>(a: A, areas: readonly Area[], isCardGone: boolean): A => {
  const onCard = a.area === UNPLANNED_AREA
  if (!onCard && !a.trail?.includes(UNPLANNED_AREA)) return a
  const to = onCard && a.file ? resolveArea(a.file, areas) : null
  if (to !== null && to !== UNPLANNED_AREA) {
    // Its stop on the unplanned card becomes a stop on the component; two stops running are one.
    const trail = a.trail?.map(t => (t === UNPLANNED_AREA ? to : t)).filter((t, i, all) => t !== all[i - 1])
    return { ...a, area: to, trail }
  }
  if (!isCardGone) return a
  return { ...a, area: onCard ? null : a.area, trail: a.trail?.filter(t => t !== UNPLANNED_AREA) }
}

/**
 * The component a shell command works in: the first path in it that one of the plan's
 * components claims, a file or a folder. Null where it names none.
 */
export const commandArea = (command: string, root: string, areas: readonly Area[]) => {
  for (const raw of command.split(/[\s;|&()<>]+/)) {
    const token = raw.replace(/^[A-Za-z_][A-Za-z0-9_]*=/, '').replace(/^['"`]+|['"`,:]+$/g, '')
    // A flag, a bare word or a number is not a path.
    if (!token || token.startsWith('-') || !/[/.]/.test(token)) continue
    const rel = relPath(root, token)
    if (!rel) continue
    // A folder is claimed where a file inside it would be.
    for (const candidate of [rel, `${rel.replace(/\/+$/, '')}/_`]) {
      const area = resolveArea(candidate, areas)
      if (area !== null && area !== UNPLANNED_AREA) return area
    }
  }
  return null
}

/** Each area's depth in the `needs` graph: 0 for one that needs nothing. A cycle stops at 12. */
export const rankAreas = (areas: readonly Area[]) => {
  const byId = new Map(areas.map(a => [a.path, a]))
  const rank = new Map<string, number>()
  const depth = (id: string, guard: number): number => {
    const known = rank.get(id)
    if (known !== undefined) return known
    if (guard > 12) return 0
    const needs = (byId.get(id)?.needs ?? []).filter(n => byId.has(n) && n !== id)
    const d = needs.length === 0 ? 0 : 1 + Math.max(...needs.map(n => depth(n, guard + 1)))
    rank.set(id, d)
    return d
  }
  for (const a of areas) depth(a.path, 0)
  return rank
}

const FILE_TOOLS = new Set(['Read', 'Edit', 'Write', 'NotebookEdit'])
const EDIT_TOOLS = new Set(['Edit', 'Write', 'NotebookEdit'])

/** The file or folder a tool call works on; empty when it names none. */
export const toolPath = (tool: string, args: Record<string, unknown>) => {
  const str = (k: string) => (typeof args[k] === 'string' ? (args[k] as string) : '')
  if (FILE_TOOLS.has(tool)) return str('file_path') || str('notebook_path')
  if (tool === 'Grep' || tool === 'Glob') return str('path')
  return ''
}

export const isEdit = (tool: string) => EDIT_TOOLS.has(tool)
/** A tool that names one file, not a folder to search. */
export const isFileTool = (tool: string) => FILE_TOOLS.has(tool)

export type Heat = 'live' | 'edited' | 'read' | 'cold'
/** How an area is drawn: someone is in it now, it was edited, it was only read, or untouched. */
export const heatOf = (stat: AreaStat | undefined, isLive: boolean): Heat =>
  isLive ? 'live' : !stat ? 'cold' : stat.edits > 0 ? 'edited' : stat.reads > 0 ? 'read' : 'cold'

/** A component's progress in a word. */
export const planStatus = (t: NonNullable<Area['tasks']>) =>
  t.total > 0 && t.done === t.total ? 'Complete' : t.stuck > 0 ? 'Blocked' : t.done > 0 || t.working > 0 ? 'In progress' : 'Not started'

/** What an agent is doing with the tool it last called, in a word. */
export const verbOf = (tool: string | null | undefined) =>
  !tool ? 'Working' : EDIT_TOOLS.has(tool) ? 'Editing' : tool === 'Read' || tool === 'Grep' || tool === 'Glob' ? 'Reading' : tool === 'Bash' ? 'Running' : 'Working'

/** How long ago, in one short unit: `5s`, `3 min`, `2 h`, `4 d`. */
export const fmtAgo = (ms: number) => {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)} min`
  if (s < 86400) return `${Math.floor(s / 3600)} h`
  return `${Math.floor(s / 86400)} d`
}

export const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`


/** A name cut to `n` characters, the last one an ellipsis. */
export const shorten = (s: string, n: number) => (s.length > n ? `${s.slice(0, Math.max(0, n - 1)).trimEnd()}…` : s)

/** Obvious secrets in a command are never shown. */
export const redact = (s: string) =>
  s
    .replace(/(bearer\s+)[\w.~+/=-]+/gi, '$1•••')
    .replace(/\b([\w-]*(?:token|secret|password|passwd|api[_-]?key)[\w-]*\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)/gi, '$1•••')
    .replace(/(:\/\/[^:/\s]+:)[^@\s]+@/g, '$1•••@')

const base = (path: string) => path.split('/').filter(Boolean).pop() ?? path

/** What a tool call is doing, in a few words: the file, the command, the pattern, or the tool's name. */
export const describeCall = (tool: string, args: Record<string, unknown>, max = 40) => {
  const str = (k: string) => (typeof args[k] === 'string' ? (args[k] as string) : '')
  const one = (s: string) => s.replace(/\s+/g, ' ').trim()
  let text = ''
  if (tool === 'Bash' || tool === 'PowerShell') text = redact(one(str('command')))
  else if (FILE_TOOLS.has(tool)) text = `${tool} ${base(str('file_path') || str('notebook_path'))}`
  else if (tool === 'Grep' || tool === 'Glob') text = `${tool} ${one(str('pattern'))}`
  else if (tool === 'Agent') text = `agent ${one(str('description'))}`
  if (!text.trim()) text = tool.startsWith('mcp__') ? (tool.split('__').pop() ?? tool) : tool
  return shorten(text, max)
}

// ── Background tasks ─────────────────────────────────────────────────────────────────────────

/** The engine's word for a background task's type, as the one the map shows; null for a subagent, which is an agent on the map already. */
export const taskKind = (type: string): string | null => {
  const t = type.toLowerCase()
  if (t.includes('remote')) return 'remote'
  if (t.includes('agent') || t.includes('teammate')) return null
  if (t.includes('shell') || t.includes('bash')) return 'shell'
  if (t.includes('monitor')) return 'monitor'
  if (t.includes('workflow')) return 'workflow'
  return shorten(t.replace(/[^a-z0-9 _-]/g, '').replace(/_/g, ' ').trim() || 'task', 12)
}

const oneLine = (text: string, max = 120) => shorten(redact(text.replace(/[\u0000-\u001f\u007f-\u009f]+/g, ' ').replace(/\s+/g, ' ').trim()), max)

/**
 * The background task a tool call left running, read from the call and its result: a shell
 * command sent to the background (or moved there), a monitor, a workflow. Null for every other call.
 */
export const taskStarted = (tool: string, args: Record<string, unknown>, result: unknown): Pick<MapTask, 'id' | 'kind' | 'what'> | null => {
  const out = (result && typeof result === 'object' ? result : {}) as Record<string, unknown>
  const str = (from: Record<string, unknown>, k: string) => (typeof from[k] === 'string' ? (from[k] as string) : '')
  if (tool === 'Bash' || tool === 'PowerShell') {
    const id = str(out, 'backgroundTaskId')
    return id ? { id, kind: 'shell', what: oneLine(str(args, 'command')) } : null
  }
  if (tool === 'Monitor') {
    const id = str(out, 'taskId')
    return id ? { id, kind: 'monitor', what: oneLine(str(args, 'command') || str(args, 'description')) } : null
  }
  if (tool === 'Workflow') {
    const id = str(out, 'taskId')
    return id ? { id, kind: taskKind(str(out, 'taskType') || 'workflow') ?? 'workflow', what: oneLine(str(out, 'workflowName') || str(args, 'name') || 'workflow') } : null
  }
  return null
}

/** How a task ended, from the word its notification or the engine's list uses. */
export const taskEnd = (status: string): MapTask['status'] => {
  const s = status.toLowerCase()
  if (/fail|error|timed?[ _-]?out/.test(s)) return 'failed'
  if (/kill|stop|cancel|abort/.test(s)) return 'stopped'
  if (/run|pending|work|start|progress/.test(s)) return 'running'
  return 'done'
}

/** The task a background notification reports on, read from the prompt it arrives as; null where it names none. */
export const parseTaskNotification = (text: string): { id: string; status: MapTask['status'] } | null => {
  const tag = (name: string) => new RegExp(`<${name}>\\s*([^<]*?)\\s*</${name}>`).exec(text)?.[1] ?? ''
  const id = tag('task-id')
  if (!id) return null
  const end = taskEnd(tag('status') || 'completed')
  // A notification that only reports progress leaves the task as it is.
  return { id, status: end }
}

/** One task of the engine's own list of what is in flight. */
export type ListedTask = { id: string; type: string; status: string; description: string; command?: string }

/**
 * The map's tasks set against the engine's list of what is in flight, which is read whenever the
 * session stops: one the map has not seen start is added, and one it holds as running that the
 * list no longer names has ended, how is not known.
 */
export const syncTasks = (tasks: readonly MapTask[], listed: readonly ListedTask[], now: number, areaOf: (command: string) => string | null): MapTask[] => {
  const inFlight = new Map(listed.flatMap(l => (taskKind(l.type) === null || taskEnd(l.status) !== 'running' ? [] : [[l.id, l] as const])))
  const kept = tasks.map(t => (t.status === 'running' && !inFlight.has(t.id) ? { ...t, status: 'done' as const, endedAt: now } : t))
  const known = new Set(tasks.map(t => t.id))
  const added = [...inFlight.values()]
    .filter(l => !known.has(l.id))
    .map((l): MapTask => ({ id: l.id, kind: taskKind(l.type) as string, what: oneLine(l.command || l.description), area: areaOf(l.command ?? ''), status: 'running', startedAt: now, endedAt: null }))
  return [...kept, ...added].slice(-TASKS_KEPT)
}
/** The map keeps this many background tasks: the oldest go first. */
export const TASKS_KEPT = 12
