// Turns what the mods drew for the demo content into pages, one per image.
import { readFileSync, writeFileSync, readdirSync } from 'node:fs'
import { parsePlan } from './hooks/core.ts'
import { drawMap } from './hooks/draw.ts'

// The work folder make.sh prepared: the mods' output as *.out, a copy of the map's drawing code.
const S = import.meta.dirname
const CELL = 9.5, ROW = 19
const trees: Record<string, any> = {}
for (const f of readdirSync(S).filter(f => f.endsWith('.out')))
  for (const line of readFileSync(`${S}/${f}`, 'utf8').split('\n'))
    if (line.startsWith('DEMO ')) { const i = line.indexOf(' ', 5); trees[line.slice(5, i)] = JSON.parse(line.slice(i + 1)) }

const esc = (s: string) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
const x = (n: unknown) => (typeof n === 'number' ? `${n * CELL}px` : String(n))
const y = (n: unknown) => (typeof n === 'number' ? `${n * ROW}px` : String(n))
const boxCss = (p: any) => {
  const c: string[] = ['display:flex', 'box-sizing:border-box']
  const put = (k: string, v: unknown) => { if (v !== undefined && v !== null) c.push(`${k}:${v}`) }
  put('flex-direction', p.flexDirection); put('flex-grow', p.flexGrow); put('flex-shrink', p.flexShrink); put('flex-wrap', p.flexWrap)
  put('align-items', p.alignItems); put('justify-content', p.justifyContent); put('align-self', p.alignSelf); put('overflow', p.overflow)
  if (p.width !== undefined) put('width', x(p.width)); if (p.height !== undefined) put('height', y(p.height)); if (p.minWidth !== undefined) put('min-width', x(p.minWidth))
  const pad = (side: string, v: unknown, horizontal: boolean) => { if (v !== undefined) c.push(`${side}:${horizontal ? x(v) : y(v)}`) }
  for (const kind of ['padding', 'margin']) {
    const all = p[kind]; if (all !== undefined) c.push(`${kind}:${y(all)} ${x(all)}`)
    pad(`${kind}-left`, p[`${kind}X`] ?? p[`${kind}Left`], true); pad(`${kind}-right`, p[`${kind}X`] ?? p[`${kind}Right`], true)
    pad(`${kind}-top`, p[`${kind}Y`] ?? p[`${kind}Top`], false); pad(`${kind}-bottom`, p[`${kind}Y`] ?? p[`${kind}Bottom`], false)
  }
  if (p.gap !== undefined) c.push(`column-gap:${x(p.gap)}`, `row-gap:${y(p.gap)}`)
  if (p.columnGap !== undefined) c.push(`column-gap:${x(p.columnGap)}`); if (p.rowGap !== undefined) c.push(`row-gap:${y(p.rowGap)}`)
  if (p.borderStyle) c.push(`border:1px solid ${p.borderColor ?? '#3b4261'}`, 'border-radius:9px')
  put('background', p.backgroundColor)
  return c.join(';')
}
const render = (n: any): string => {
  if (n === null || n === undefined || n === false) return ''
  if (typeof n === 'string') return esc(n)
  if (Array.isArray(n)) return n.map(render).join('')
  const p = n.props ?? {}, kids = (n.children ?? []).map(render).join('')
  if (n.type === 'Box') return `<div style="${boxCss(p)}">${kids}</div>`
  if (n.type === 'Text') {
    const c = [`color:${p.color ?? '#c0caf5'}`, 'white-space:pre-wrap']
    if (p.bold) c.push('font-weight:600'); if (p.dimColor) c.push('opacity:.55')
    if (String(p.wrap ?? '').startsWith('truncate')) c.push('white-space:nowrap', 'overflow:hidden', 'text-overflow:ellipsis', 'min-width:0')
    return `<span style="${c.join(';')}">${kids}</span>`
  }
  if (n.type === 'Button') {
    const label = esc(String(p.label ?? kids))
    if (p.plain) return `<span class="plain" style="color:${p.dimColor ? '#737aa2' : '#c0caf5'}">${label}</span>`
    return `<span class="btn ${p.variant === 'primary' ? 'primary' : ''}">${label}</span>`
  }
  if (n.type === 'Select') return `<span class="btn">${esc(String((p.options ?? []).find((o: any) => o.value === p.value)?.label ?? ''))} <span style="color:#737aa2">▾</span></span>`
  if (n.type === 'Input') return `<span style="display:flex;align-items:center;column-gap:${CELL}px">${p.label ? `<span style="color:#737aa2">${esc(p.label)}</span>` : ''}<span class="input">${p.value ? esc(p.value) : `<span style="color:#565f89">${esc(p.placeholder ?? '')}</span>`}</span>${p.submitLabel ? `<span class="plain" style="color:#737aa2">${esc(p.submitLabel)}</span>` : ''}</span>`
  if (n.type === 'Svg') {
    const w = p.width ? `${p.width}px` : '100%', hgt = p.height ? `${p.height}px` : 'auto'
    const src = String(p.source).replace(/^<svg /, `<svg style="display:block;width:${w};height:${hgt}" `)
    return `<div style="width:${w};line-height:0;flex-shrink:0;${p.width ? '' : 'flex-grow:1;min-width:0'}">${src}</div>`
  }
  return kids
}
const page = (name: string, width: number, body: string, title = '') => {
  const html = `<!doctype html><meta charset="utf-8"><style>
html,body{margin:0;background:#16161e}
#shot{padding:18px;width:${width}px;box-sizing:content-box}
.panel{background:#1a1b26;border:1px solid #292e42;border-radius:12px;padding:${ROW}px ${2 * CELL}px;font:13px/${ROW}px -apple-system,"SF Pro Text",system-ui,sans-serif;color:#c0caf5}
.title{color:#565f89;font:600 11px/16px -apple-system,system-ui,sans-serif;letter-spacing:.06em;text-transform:uppercase;margin:0 0 10px 4px}
.btn{display:inline-block;border:1px solid #3b4261;background:#24283b;color:#c0caf5;border-radius:6px;padding:1px 9px;font-size:12px;font-weight:500;white-space:nowrap}
.btn.primary{background:#7aa2f7;border-color:#7aa2f7;color:#16161e;font-weight:600}
.plain{white-space:nowrap;flex-shrink:0}
.input{display:inline-block;border:1px solid #3b4261;background:#16161e;border-radius:6px;padding:1px 9px;min-width:${20 * CELL}px;font-size:12px}
</style><div id="shot">${title ? `<div class="title">${esc(title)}</div>` : ''}${body}</div>`
  writeFileSync(`${S}/${name}.html`, html)
  console.log(name, width + 36)
}
// The one element of a drawing that carries this key.
const find = (n: any, key: string): any => (!n || typeof n !== 'object' ? null : n.props?.key === key ? n : (n.children ?? []).map((c: any) => find(c, key)).find(Boolean) ?? null)
const panel = (tree: any, cols: number) => `<div class="panel" style="width:${cols * CELL}px">${render(tree)}</div>`
const cols = 118, W = cols * CELL + 4 * CELL + 2

page('git-graph', W, panel(trees['graph-commit'], cols), 'Git graph')
page('git-graph-confirm', W, panel(trees['graph-confirm'], cols), 'Git graph: an action waits for Run')
page('git-graph-toasts', W, `<div class="panel" style="width:${cols * CELL}px;display:flex;flex-direction:column;row-gap:${ROW}px">${render(find(trees['toast-done'], 'toast-row'))}${render(find(trees['toast-refused'], 'toast-row'))}</div>`, 'Git graph: what an action did, at the foot of the panel')
page('status-band', W, panel(trees['band'], cols), 'Status band')
page('status-band-folded', W, panel(trees['band-folded'], cols), 'Status band, folded')
page('status-band-narrow', 62 * CELL + 4 * CELL + 2, panel(trees['band-narrow'], 62), 'Status band, narrow')
const session = (c: string) => `<div class="panel" style="width:${46 * CELL}px;display:flex;flex-direction:column;row-gap:${ROW}px">${render(trees[`tint-${c}-prompt`])}<div>${render(trees[`tint-${c}-spinner`])}</div><div>${render(trees[`tint-${c}-done`])}</div>${render(trees[`tint-${c}-rule`])}</div>`
page('session-tint', 3 * (46 * CELL + 4 * CELL + 2) + 2 * 18, `<div style="display:flex;column-gap:18px;align-items:flex-start">${['purple', 'teal', 'orange'].map(session).join('')}</div>`, 'Session tint: three sessions')

// The project map, drawn by the mod's own code from a demo plan with three agents at work.
const PLAN = readFileSync(`${S}/demo-plan.md`, 'utf8')
const plan = parsePlan(PLAN).map(a => ({ ...a, files: 6 }))
const now = 1_000_000
const agent = (id: string, name: string, area: string, doing: string | null, file: string | null, lastTool: string, trail: string[]) => ({ id, name, status: 'running', area, doing, file, lastTool, tools: 5, startedAt: 0, endedAt: null, trail })
const agents = [
  agent('main', 'session', 'api', 'Edit telemetry/batch.go', 'api/internal/telemetry/batch.go', 'Edit', ['api']),
  agent('a1', 'Explore', 'firmware', 'Read src/ota.c', 'firmware/src/ota.c', 'Read', ['gateway', 'firmware']),
  agent('a2', 'test-runner', 'dashboard', 'npm test -- gusts', null, 'Bash', ['api', 'dashboard']),
]
const stats = {
  api: { reads: 3, edits: 4, lastAt: now - 3000, lastBy: 'main', recent: [{ file: 'api/internal/telemetry/batch.go', reads: 1, edits: 3, at: now - 3000 }, { file: 'api/internal/telemetry/routes.go', reads: 2, edits: 1, at: now - 95_000 }] },
  firmware: { reads: 2, edits: 0, lastAt: now - 6000, lastBy: 'a1', recent: [{ file: 'firmware/src/ota.c', reads: 2, edits: 0, at: now - 6000 }] },
  gateway: { reads: 1, edits: 0, lastAt: now - 240_000, lastBy: 'a1', recent: [{ file: 'gateway/internal/ota/push.go', reads: 1, edits: 0, at: now - 240_000 }] },
}
// Two things left running in the background, and one that has ended since the last prompt.
const tasks = [
  { id: 'b1', kind: 'shell', what: 'npm --prefix dashboard run dev', area: 'dashboard', status: 'running', startedAt: now - 190_000, endedAt: null },
  { id: 'm1', kind: 'monitor', what: 'tail -f /var/log/gateway.log', area: null, status: 'running', startedAt: now - 40_000, endedAt: null },
  { id: 'b2', kind: 'shell', what: 'go test ./telemetry/...', area: 'api', status: 'failed', startedAt: now - 150_000, endedAt: now - 75_000 },
]
const live = drawMap({ areas: plan as never, stats: stats as never, agents: agents as never, tasks: tasks as never, width: 1160, now, unfolded: { states: [], card: null } as never })
page('project-map', live.width, `<div style="line-height:0;border-radius:12px;overflow:hidden;background:#1a1b26">${live.source}</div>`, 'Project map: three agents at work, two tasks in the background')
const rest = drawMap({ areas: plan as never, stats: {} as never, agents: [] as never, width: 1160, now, unfolded: { states: ['todo'], card: null } as never })
page('project-map-rest', rest.width, `<div style="line-height:0;border-radius:12px;overflow:hidden;background:#1a1b26">${rest.source}</div>`, 'Project map at rest, "To do" unfolded')
