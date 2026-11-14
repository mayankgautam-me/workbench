import { expect, test } from 'claude-code/testing'

import {
  UNPLANNED_AREA, describeCall, fmtAgo, heatOf, matchesGlob, parsePlan,
  planStatus, rankAreas, rehomeAgent, rehomeUnplanned, relPath, resolveArea, toolPath, verbOf, lintPlan, planReport, commandArea, parseTaskNotification, syncTasks, taskKind, taskStarted,
} from '../hooks/core'
import { drawMap } from '../hooks/draw'

test('tool paths are made relative to the project, and ones outside it are left out', async () => {
  expect(relPath('/p/app', '/p/app/src/a.ts')).toBe('src/a.ts')
  expect(relPath('/p/app', './src/a.ts')).toBe('src/a.ts')
  expect(relPath('/p/app', '/etc/hosts')).toBe(null)
  expect(relPath('/p/app', '/p/application/a.ts')).toBe(null)
  expect(toolPath('Edit', { file_path: '/p/app/a.ts' })).toBe('/p/app/a.ts')
  expect(toolPath('Grep', { pattern: 'x', path: 'src' })).toBe('src')
  expect(toolPath('Bash', { command: 'ls' })).toBe('')
})

test('heat: working now beats edited, edited beats read', async () => {
  const stat = { reads: 3, edits: 1, lastAt: 1, lastBy: 'main' }
  expect(heatOf(stat, true)).toBe('live')
  expect(heatOf(stat, false)).toBe('edited')
  expect(heatOf({ ...stat, edits: 0 }, false)).toBe('read')
  expect(heatOf(undefined, false)).toBe('cold')
})

test('a command shown on the map never carries an obvious secret', async () => {
  expect(describeCall('Bash', { command: 'curl -H "Authorization: Bearer abc123" https://x' }, 80)).not.toContain('abc123')
  expect(describeCall('Read', { file_path: '/p/app/src/page.tsx' })).toBe('Read page.tsx')
})

const PLAN = `# demo

## Capture the audio {#capture}
tech: coreaudio tap
files: [src/audio/**, tools/tap.c]
- [x] Grab the mic feed {#capture-mic}
  by: claude
- [~] Keep the last 30 seconds ready {#capture-ring}

## Classify the alerts {#classify}
needs: [capture]
links: [notify]
files: [src/classify]
- [ ] Score events {#classify-score}
- [!] Tune thresholds {#classify-tune}

## Notify {#notify}
kind: human
needs: [classify]

## decisions
- 2026-08-21: dropped redis
`

test('a PLAN.md in the agenttrail convention becomes the map: components, globs, needs and tasks', async () => {
  const plan = parsePlan(PLAN)
  expect(plan.map(c => c.path)).toEqual(['capture', 'classify', 'notify'])
  expect(plan[0]?.title).toBe('Capture the audio')
  expect(plan[0]?.tech).toBe('coreaudio tap')
  expect(plan[0]?.globs).toEqual(['src/audio/**', 'tools/tap.c'])
  expect(plan[0]?.tasks).toEqual({ done: 1, working: 1, stuck: 0, total: 2 })
  expect(plan[1]?.needs).toEqual(['capture'])
  expect(plan[1]?.links).toEqual(['notify'])
  expect(plan[1]?.tasks).toEqual({ done: 0, working: 0, stuck: 1, total: 2 })
  expect(plan[2]?.kind).toBe('human')
  expect(parsePlan('# just a readme\n\n## Usage\ntext')).toEqual([])
})

test('a file touched while unplanned moves to the component that later claims it', async () => {
  const plan = parsePlan(PLAN)
  const loose = { reads: 1, edits: 2, lastAt: 9, lastBy: 'main', lastFile: 'tap.c', lastFileCalls: 2 }
  const tap = { file: 'src/audio/tap.c', reads: 0, edits: 2, at: 9 }
  const readme = { file: 'README.md', reads: 1, edits: 0, at: 5 }

  // Every file on the card is claimed now: the entry goes, and the card with it.
  const all = rehomeUnplanned({ [UNPLANNED_AREA]: { ...loose, reads: 0, recent: [tap] } }, plan)
  expect(all[UNPLANNED_AREA]).toBe(undefined)
  expect(all.capture?.edits).toBe(2)
  expect(all.capture?.lastFile).toBe('tap.c')
  expect(all.capture?.recent?.[0]?.file).toBe('src/audio/tap.c')

  // One file is still unclaimed: it stays, with only its own counts.
  const some = rehomeUnplanned({ [UNPLANNED_AREA]: { ...loose, recent: [tap, readme] } }, plan)
  expect(some[UNPLANNED_AREA]?.recent).toEqual([readme])
  expect(some[UNPLANNED_AREA]?.edits).toBe(0)
  expect(some[UNPLANNED_AREA]?.lastFile).toBe('README.md')
  expect(some.capture?.edits).toBe(2)

  // Nothing claimed, or nothing recorded: left as it was.
  const none = { [UNPLANNED_AREA]: { ...loose, recent: [readme] } }
  expect(rehomeUnplanned(none, plan)).toEqual(none)
})

test('globs claim files for a component; a file none claims is unplanned', async () => {
  expect(matchesGlob('src/audio/**', 'src/audio/ring/buf.c')).toBe(true)
  expect(matchesGlob('src/*.ts', 'src/a.ts')).toBe(true)
  expect(matchesGlob('src/*.ts', 'src/x/a.ts')).toBe(false)
  expect(matchesGlob('**/*.md', 'docs/a.md')).toBe(true)
  expect(matchesGlob('src/classify', 'src/classify/score.ts')).toBe(true)
  expect(matchesGlob('src/classify', 'src/classifyx/score.ts')).toBe(false)
  const plan = parsePlan(PLAN)
  expect(resolveArea('src/audio/tap.c', plan)).toBe('capture')
  expect(resolveArea('src/classify/score.ts', plan)).toBe('classify')
  expect(resolveArea('README.md', plan)).toBe(UNPLANNED_AREA)
  // Without a plan a path belongs to nothing.
  expect(resolveArea('apps/web/a.ts', [])).toBe(null)
})

test('components rank by what they need, and a cycle does not hang', async () => {
  const rank = rankAreas(parsePlan(PLAN))
  expect([rank.get('capture'), rank.get('classify'), rank.get('notify')]).toEqual([0, 1, 2])
  const loop = rankAreas([{ path: 'a', files: 0, needs: ['b'] }, { path: 'b', files: 0, needs: ['a'] }])
  expect(typeof loop.get('a')).toBe('number')
})

// Every task group unfolded, as the row above the map can set it.
const ALL = { states: [], card: '*' } as const

test('the drawing has a card per component, an arrow per need and a mark per agent', async () => {
  const plan = parsePlan(PLAN)
  const agents = [
    { id: 'main', name: 'session', status: 'running', area: 'classify', doing: 'Edit <score>.ts', lastTool: 'Edit', tools: 1, startedAt: 0, endedAt: null, trail: ['capture', 'classify'], file: 'src/score.ts', movedAt: 64_700 },
    { id: 'a1', name: 'Runner', status: 'running', area: 'capture', loose: true, doing: 'make test', lastTool: 'Bash', tools: 1, startedAt: 0, endedAt: null },
  ] as never
  const stats = {
    classify: { reads: 1, edits: 2, lastAt: 60_000, lastBy: 'main' },
    capture: { reads: 3, edits: 0, lastAt: 30_000, lastBy: 'main', lastFile: 'tap.c', lastFileCalls: 3, recent: [{ file: 'src/tap.c', reads: 3, edits: 0, at: 30_000 }] },
  }
  const drawn = drawMap({ unfolded: ALL, areas: plan, stats, agents, width: 760, now: 65_000 })
  expect(drawn.source.startsWith('<svg ')).toBe(true)
  expect(drawn.source.length).toBeLessThan(131072)
  for (const piece of [
    'Capture the audio', 'Classify the alerts', 'coreaudio tap', '1 of 2 tasks · In progress', '0 of 2 tasks · Blocked',
    'Edit &lt;score&gt;.ts', '>Editing<', 'Grab the mic feed', 'Keep the last 30 seconds ready', 'Tune thresholds', '>tap.c<', '>read · ×3 · under a minute<', '>score.ts<', '>in use now<', 'marker-end="url(#move-0)"', '<animate ',
    // The live card breathes and spins; each agent has a row, on the session card and on the card it is in;
    // an agent running a command with no file stays on the card it last worked in.
    '<animateTransform ', '<animateMotion ', '>session<', '>Runner<', '>make test<', '>in Classify the alerts<', '>in Capture the audio<', 'begin="-',
    'stroke-dasharray="7 5"',
  ]) {
    expect(drawn.source).toContain(piece)
  }
  // Three components and the session card above them.
  expect(drawn.source.match(/ rx="10"/g)?.length).toBe(4)
  expect(drawMap({ unfolded: ALL, areas: plan, stats: {}, agents: [], width: 760 }).source.match(/ rx="10"/g)?.length).toBe(3)
  // Two arrows of the plan, still and grey, and one agent's move in its colour over them.
  expect(drawn.source.match(/marker-end="url\(#arrow\)"/g)?.length).toBe(2)
  expect(drawn.source.match(/marker-end="url\(#move-/g)?.length).toBe(1)
  expect(drawn.source).not.toContain('arrow-live')
  // A plan's `links:` are not drawn: only what a component needs.
  expect(drawn.source).not.toContain('stroke-dasharray="2 7"')
  expect(drawn.alt).toContain('session: Edit <score>.ts in Classify the alerts; Runner: make test in Capture the audio')
  // The move is drawn after the plan's arrows, so nothing lies over it.
  expect(drawn.source.lastIndexOf('url(#arrow)"')).toBeLessThan(drawn.source.indexOf('url(#move-0)"'))
  // The plan runs top to bottom at any width: a row per rank, each card under what it needs.
  const ys = (svg: string) => [...svg.matchAll(/<rect x="[\d.]+" y="([\d.]+)" width="\d+" height="[\d.]+" rx="10"/g)].map(m => Number(m[1]))
  expect(new Set(ys(drawn.source)).size).toBe(4)
  // A row's cards share the full width: nothing is left empty beside a short row.
  const wide = drawMap({ unfolded: ALL, areas: plan, stats: {}, agents: [], width: 1500 }).source
  for (const m of wide.matchAll(/<rect x="([\d.]+)" y="[\d.]+" width="(\d+)" height="[\d.]+" rx="10"/g)) expect(Number(m[1]) + Number(m[2])).toBeGreaterThan(700)
  expect(new Set(ys(drawMap({ unfolded: ALL, areas: plan, stats: {}, agents: [], width: 1500 }).source)).size).toBe(3)
  // A card lists its tasks, so a row is as tall as its longest list.
  const long = [{ path: 'big', title: 'Big', files: 0, taskList: Array.from({ length: 14 }, (_, i) => ({ text: `task ${i}`, state: 'todo' as const })) }, { path: 'small', title: 'Small', files: 0 }]
  const tall = drawMap({ unfolded: ALL, areas: long, stats: {}, agents: [], width: 700 })
  // Every task is listed: nothing is cut to "N more".
  expect(tall.source).toContain('task 13')
  expect(tall.source).not.toContain(' more<')
  expect(new Set([...tall.source.matchAll(/height="([\d.]+)" rx="10"/g)].map(m => m[1])).size).toBe(1)
  expect(tall.height).toBeGreaterThan(drawMap({ unfolded: ALL, areas: [long[1] as never], stats: {}, agents: [], width: 700 }).height)
  // A task too long for one line takes two, the second cut with an ellipsis.
  const words = 'alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau'
  const wrapped = drawMap({ unfolded: ALL, areas: [{ path: 'w', title: 'W', files: 0, taskList: [{ text: words, state: 'todo' }] }], stats: {}, agents: [], width: 300 }).source
  expect(wrapped).not.toContain(words)
  expect(wrapped).toContain('>alpha beta gamma')
  expect(wrapped).toContain('…</text>')
  // A narrow panel lays the map out narrower and draws it larger, in one column.
  const docked = drawMap({ unfolded: ALL, areas: plan, stats: {}, agents: [], width: 400 })
  expect(docked.source).toContain('width="400"')
  expect(docked.source).toContain('viewBox="0 0 320 ')
  expect(new Set([...docked.source.matchAll(/<rect x="([\d.]+)" y="[\d.]+" width="\d+" height="[\d.]+" rx="10"/g)].map(m => m[1])).size).toBe(1)
  // In one column the arrows are left out, as they would only be lines through the cards.
  expect(drawMap({ unfolded: ALL, areas: plan, stats: {}, agents: [], width: 300 }).source).not.toContain('marker-end=')
  const folders = [{ path: 'a', title: 'A', files: 1 }, { path: 'b', title: 'B', files: 1 }, { path: 'c', title: 'C', files: 1 }]
  expect(drawMap({ unfolded: ALL, areas: folders, stats: {}, agents: [], width: 300 }).height).toBeGreaterThan(
    drawMap({ unfolded: ALL, areas: folders, stats: {}, agents: [], width: 640 }).height,
  )
})

test('a plan keeps its tasks in words, and a component says its progress in one', async () => {
  const plan = parsePlan(PLAN)
  expect(plan[0]?.taskList).toEqual([
    { text: 'Grab the mic feed', state: 'done' },
    { text: 'Keep the last 30 seconds ready', state: 'working' },
  ])
  expect(plan[1]?.taskList?.map(t => t.state)).toEqual(['todo', 'stuck'])
  expect(planStatus({ done: 2, working: 0, stuck: 0, total: 2 })).toBe('Complete')
  expect(planStatus({ done: 1, working: 0, stuck: 1, total: 3 })).toBe('Blocked')
  expect(planStatus({ done: 0, working: 1, stuck: 0, total: 3 })).toBe('In progress')
  expect(planStatus({ done: 0, working: 0, stuck: 0, total: 3 })).toBe('Not started')
})

test('times are one short unit, and a tool is one word', async () => {
  expect(fmtAgo(4_600)).toBe('5s')
  expect(fmtAgo(125_000)).toBe('2 min')
  expect(fmtAgo(15 * 3_600_000)).toBe('15 h')
  expect(fmtAgo(3 * 86_400_000)).toBe('3 d')
  expect(fmtAgo(-50)).toBe('0s')
  expect(verbOf('Write')).toBe('Editing')
  expect(verbOf('Grep')).toBe('Reading')
  expect(verbOf('Bash')).toBe('Running')
  expect(verbOf(null)).toBe('Working')
})


test('a sound PLAN.md has nothing to report; each thing the map cannot read is named by line', async () => {
  const good = '# demo\n\n## Web {#web}\ntech: svelte\nfiles: [apps/web/**]\n- [x] Ship {#web-ship}\n- [~] Form\n\n## API {#api}\nfiles: [services/api/**]\nneeds: [web]\n- [!] Auth\n\n## decisions\n- [2026] prose here is not a task\n'
  expect(lintPlan(good, ['apps/web/a.ts', 'services/api/main.go'])).toEqual([])
  // A glob that claims nothing is a note, not an error: the work may not have started.
  expect(lintPlan(good, ['apps/web/a.ts']).map(p => p.level)).toEqual(['note'])

  const bad = [
    '# demo',
    '## Web {#web}',
    '- files: [apps/web/**]',
    'file: [x]',
    '  - [ ] indented',
    '- [] no mark',
    '* [ ] star',
    '- [ ] ok {#t1}',
    '- [ ] again {#t1}',
    'needs: [ghost, web]',
    '## API {#web}',
    'files: [/abs/**]',
    '## Bad {#has space}',
    '- [ ] orphan',
  ].join('\n')
  const report = planReport(lintPlan(bad))
  for (const piece of [
    'PLAN.md:3: error: `files:` is written as a list item', 'PLAN.md:4: error: `file:` is not a field', 'did you mean `files:`',
    'PLAN.md:5: error: task is not read because it is indented', 'PLAN.md:6: error', '`[]` is not a mark', 'PLAN.md:7: error',
    'PLAN.md:9: error: task id {#t1} is already used on line 8', 'names {#ghost}', 'names itself',
    'PLAN.md:11: error: component id {#web} is already used on line 2', 'PLAN.md:12: error: glob `/abs/**`',
    'PLAN.md:13: error: heading has a malformed id', 'PLAN.md:14: error: task is not under',
  ]) expect(report).toContain(piece)

  expect(planReport(lintPlan('# notes\n\n## Ideas\n- one\n'))).toContain('no component found')
  expect(planReport(lintPlan('## A {#a}\nfiles: [a]\nneeds: [b]\n## B {#b}\nfiles: [b]\nneeds: [a]\n'))).toContain('goes in a circle: a → b → a')
})

test('a shell command lights the component whose files it names', async () => {
  const plan = parsePlan('## Web {#web}\nfiles: [apps/web/**]\n\n## API {#api}\nfiles: [services/api/**, Makefile]\n')
  const at = (command: string) => commandArea(command, '/p', plan)
  expect(at('cd /p && npm test --prefix apps/web')).toBe('web')
  expect(at('go test ./services/api/... 2>&1 | tail -3')).toBe('api')
  expect(at('cat "/p/services/api/main.go"')).toBe('api')
  expect(at('make -f ./Makefile build')).toBe('api')
  expect(at('OUT=apps/web/dist vite build')).toBe('web')
  // No path of the plan's, a path outside the project, or only flags: no card.
  for (const none of ['git status', 'ls -la', 'cat /etc/hosts', 'npm run build', 'echo done.']) expect(at(none)).toBe(null)
})

test('a card groups its tasks by status, each group one line until it is unfolded', async () => {
  const plan = parsePlan(PLAN)
  const folded = drawMap({ areas: plan, stats: {}, agents: [], width: 760 })
  // Folded: the groups with their counts. What is in progress is always listed; the rest is not.
  for (const piece of ['>Done · 1<', '>In progress · 1<', 'Keep the last 30 seconds ready']) expect(folded.source).toContain(piece)
  for (const hidden of ['Grab the mic feed', 'Tune thresholds']) expect(folded.source).not.toContain(hidden)
  // One status unfolded on every card; the others stay folded.
  const done = drawMap({ areas: plan, stats: {}, agents: [], width: 760, unfolded: { states: ['done'], card: '' } })
  expect(done.source).toContain('Grab the mic feed')
  expect(done.source).not.toContain('Tune thresholds')
  // One card unfolded whole; the others stay folded.
  const one = drawMap({ areas: plan, stats: {}, agents: [], width: 760, unfolded: { states: [], card: 'capture' } })
  for (const piece of ['Grab the mic feed', 'Keep the last 30 seconds ready']) expect(one.source).toContain(piece)
  expect(one.source).not.toContain('Tune thresholds')
  // At rest an in-progress mark is still: nothing on the map moves when nobody is working.
  expect(drawMap({ areas: plan, stats: {}, agents: [], width: 760, unfolded: ALL }).source).not.toContain('<animate')
  expect(folded.height).toBeLessThan(drawMap({ areas: plan, stats: {}, agents: [], width: 760, unfolded: ALL }).height)
})

test('at rest the drawing does not change from one moment to the next, so it is not replaced', async () => {
  const plan = parsePlan(PLAN)
  const stats = { capture: { reads: 1, edits: 1, lastAt: 1_000_000, lastBy: 'main', recent: [{ file: 'src/tap.c', reads: 1, edits: 1, at: 1_000_000 }] } }
  const idle = [{ id: 'main', name: 'session', status: 'idle', area: 'capture', doing: null, tools: 3, startedAt: 0, endedAt: 1_000_000 }] as never
  const at = (now: number) => drawMap({ areas: plan, stats, agents: idle, width: 760, now, unfolded: ALL }).source
  // Twenty seconds apart, a few minutes after the last touch: the same drawing, byte for byte.
  expect(at(1_200_000)).toBe(at(1_220_000))
  expect(at(1_200_000)).not.toContain('<animate')
  // And it does change once the minute turns.
  expect(at(1_200_000)).not.toBe(at(1_290_000))
})

test('agents on the move never share a line: each has its own track in a gap, in the margin and on a card edge', () => {
  const stack = parsePlan(['a', 'b', 'c', 'd'].map(id => `## ${id.toUpperCase()} {#${id}}\nfiles: [${id}/**]\n`).join('\n'))
  const mover = (id: string, trail: string[]) => ({ id, name: id, status: 'running', area: trail[1], doing: 'Read x', lastTool: 'Read', tools: 1, startedAt: 0, endedAt: null, trail })
  // A narrow panel: one column, so both moves from A to further down go round by the left margin.
  const drawn = drawMap({ unfolded: ALL, areas: stack, stats: {}, agents: [mover('one', ['a', 'c']), mover('two', ['a', 'd'])] as never, width: 420, now: 1000 }).source
  const paths = [...drawn.matchAll(/<path d="([^"]+)"[^>]*stroke-dasharray="6 6"/g)].map(m => (m[1] as string).match(/-?[\d.]+/g)?.map(Number) ?? [])
  expect(paths.length).toBe(2)
  const [p, q] = paths as [number[], number[]]
  // They leave the card 12 apart, run under it 12 apart, and go down the margin 12 apart.
  expect(Math.abs((p[0] as number) - (q[0] as number))).toBe(12)
  const xs = (path: number[]) => Math.min(...path.filter((_, i) => i % 2 === 0))
  expect(Math.abs(xs(p) - xs(q))).toBe(12)
  const firstTurn = (path: number[]) => path[3] as number
  expect(Math.abs(firstTurn(p) - firstTurn(q))).toBeGreaterThanOrEqual(11)
  // The cards stand 16 clear of the nearest line in the margin.
  const cardX = Number(drawn.match(/<rect x="([\d.]+)" y="[\d.]+" width="[\d.]+" height="[\d.]+" rx="10"/)?.[1])
  expect(cardX - Math.max(xs(p), xs(q))).toBe(16)
})

test('an agent that has ended, and the session between turns, leave no dot on their card', () => {
  const plan = parsePlan('## Web {#web}\nfiles: [apps/web/**]\n\n## API {#api}\nfiles: [services/api/**]\n')
  const agent = (id: string, status: string, doing: string | null, area: string) => ({ id, name: id, status, area, doing, lastTool: 'Read', tools: 1, startedAt: 0, endedAt: status === 'running' ? null : 5, trail: [area] })
  const rest = drawMap({ unfolded: ALL, areas: plan, stats: {}, agents: [agent('main', 'idle', null, 'web'), agent('a1', 'completed', null, 'api')] as never, width: 760, now: 1000 }).source
  const empty = drawMap({ unfolded: ALL, areas: plan, stats: {}, agents: [], width: 760, now: 1000 }).source
  // The map with only ended agents is the map with none.
  expect(rest).toBe(empty)
  expect(rest).not.toContain('r="4.5"')
  // While one works, its row is on its card.
  const busy = drawMap({ unfolded: ALL, areas: plan, stats: {}, agents: [agent('a1', 'running', 'Read x', 'api')] as never, width: 760, now: 1000 }).source
  expect(busy).toContain('>a1<')
})

test('an agent moves with its file when a component claims it; a reload that moves nothing changes nothing', () => {
  const plan = parsePlan('## Web {#web}\nfiles: [web/**]\n\n## API {#api}\nfiles: [api/**]\n')
  // Its file is claimed: it moves to that component although other files are still unplanned.
  const onCard = { id: 'a1', area: UNPLANNED_AREA, file: 'api/x.go', trail: ['web', UNPLANNED_AREA] }
  expect(rehomeAgent(onCard, plan, false)).toEqual({ id: 'a1', area: 'api', file: 'api/x.go', trail: ['web', 'api'] })
  // Coming from the component it now belongs to, the two stops are one: no move is left to draw.
  expect(rehomeAgent({ ...onCard, trail: ['api', UNPLANNED_AREA] }, plan, false).trail).toEqual(['api'])
  // Its file is still unplanned: it stays while the card does, and leaves it when the card goes.
  const loose = { id: 'a2', area: UNPLANNED_AREA, file: 'notes.txt', trail: [UNPLANNED_AREA] }
  expect(rehomeAgent(loose, plan, false)).toBe(loose)
  expect(rehomeAgent(loose, plan, true)).toEqual({ id: 'a2', area: null, file: 'notes.txt', trail: [] })
  // One that only passed through keeps its place, and forgets the card once it is gone.
  const passed = { id: 'a3', area: 'web', file: 'web/a.ts', trail: [UNPLANNED_AREA, 'web'] }
  expect(rehomeAgent(passed, plan, false)).toBe(passed)
  expect(rehomeAgent(passed, plan, true).trail).toEqual(['web'])
  // Nothing to do with the card: the same object, so nothing is written.
  const elsewhere = { id: 'a4', area: 'web', file: 'web/a.ts', trail: ['web'] }
  expect(rehomeAgent(elsewhere, plan, true)).toBe(elsewhere)
  // The touches too: with nothing to move, the same object comes back.
  const stats = { web: { reads: 1, edits: 0, lastAt: 10, lastBy: 'main' }, [UNPLANNED_AREA]: { reads: 2, edits: 0, lastAt: 20, lastBy: 'a2', recent: [{ file: 'notes.txt', reads: 2, edits: 0, at: 20 }] } }
  expect(rehomeUnplanned(stats, plan)).toBe(stats)
  expect(rehomeUnplanned({ web: stats.web }, plan)).toEqual({ web: stats.web })
})

test('background tasks are read from the call that left them running, their notification and the list of what is in flight', () => {
  expect(taskStarted('Bash', { command: 'npm run dev -- --token=abc123' }, { stdout: '', backgroundTaskId: 'b1' })).toEqual({ id: 'b1', kind: 'shell', what: 'npm run dev -- --token=•••' })
  expect(taskStarted('Bash', { command: 'ls' }, { stdout: 'a' })).toBe(null)
  expect(taskStarted('Monitor', { description: 'gateway log', command: 'tail -f\tgateway.log' }, { taskId: 'm1', timeoutMs: 0 })).toEqual({ id: 'm1', kind: 'monitor', what: 'tail -f gateway.log' })
  expect(taskStarted('Workflow', {}, { status: 'async_launched', taskId: 'w1', taskType: 'local_workflow', workflowName: 'review-changes' })).toEqual({ id: 'w1', kind: 'workflow', what: 'review-changes' })
  expect(taskStarted('Read', { file_path: 'a' }, { taskId: 'x' })).toBe(null)

  expect(parseTaskNotification('<task-notification>\n<task-id>b1</task-id>\n<status>failed</status>\n<summary>exit 1</summary>\n</task-notification>')).toEqual({ id: 'b1', status: 'failed' })
  expect(parseTaskNotification('<task-notification><task-id>b1</task-id><status>killed</status></task-notification>')).toEqual({ id: 'b1', status: 'stopped' })
  expect(parseTaskNotification('<task-notification><task-id>b1</task-id><status>completed</status></task-notification>')).toEqual({ id: 'b1', status: 'done' })
  expect(parseTaskNotification('a prompt')).toBe(null)

  // A subagent is an agent on the map, not a task; one gone from the list has ended; a new one is added.
  expect(taskKind('subagent')).toBe(null)
  const held = [{ id: 'b1', kind: 'shell', what: 'npm run dev', area: 'web', status: 'running' as const, startedAt: 1, endedAt: null }, { id: 'b2', kind: 'shell', what: 'pytest', area: null, status: 'running' as const, startedAt: 2, endedAt: null }]
  const synced = syncTasks(held, [{ id: 'b2', type: 'shell', status: 'running', description: 'tests', command: 'pytest' }, { id: 'a9', type: 'subagent', status: 'running', description: 'Explore' }, { id: 'm3', type: 'monitor', status: 'running', description: 'watch the log', command: 'tail -f services/api/log' }], 50, c => (c.includes('services/api') ? 'api' : null))
  expect(synced.map(t => [t.id, t.status, t.area, t.endedAt])).toEqual([['b1', 'done', 'web', 50], ['b2', 'running', null, null], ['m3', 'running', 'api', null]])
})
