import { expect, mock, test } from 'claude-code/testing'

const PANE_PROPS = { title: 'Project map', isFocused: false, bodyColumns: 120, placement: 'dock' } as never
const BAND_PROPS = { hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120 } as never

const TWO = '# demo\n\n## Web app {#web}\nfiles: [apps/web/**]\n- [x] Ship the page\n- [~] Wire the form\n\n## API {#api}\nneeds: [web]\nfiles: [services/api/**]\n'

test('the panel is the map alone: components with their tasks, and who is working where', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('prompt.compose', async () => ({ sections: [{ id: 'intro', text: 'You are Claude.', scope: 'shared' }] }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('store.set', async () => ({ value: undefined }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  let plan = TWO
  on('fs.read', async () => ({ value: plan }) as never)
  let t = 1_000_000
  on('clock.now', async () => ({ value: t }) as never)
  on('agent.spawn', async () => ({ agentId: 'a1', model: 'haiku' }) as never)
  on('turn.complete', async () => ({ text: '' }) as never)
  let midCall = ''
  on('tool.call', async (_$, e) => {
    if ((e as { tool_use_id?: string }).tool_use_id === 't2') {
      // While the subagent's read runs, its dot sits on that component's row (the terminal's list).
      const ui = await $.ui.mount({ plugin: 'agent-map', surface: 'terminal', component: 'Pane', requestId: 'agent-map', props: PANE_PROPS })
      midCall = JSON.stringify(await ui.drawn())
      await ui.unmount()
    }
    return { result: { text: 'ok' } } as never
  })

  // /map reads the plan: its components are the map.
  await $.command.run({ command: 'map' } as never)
  // The plan has a task in progress, so an edit carries no reminder.
  const edited = await $.tool.call({ tool: 'Edit', tool_use_id: 't1', file_path: 'apps/web/src/page.tsx' } as never)
  expect(JSON.stringify(edited)).not.toContain('no task in PLAN.md is marked in progress')
  // The system prompt gains the plan-first section in a project with a PLAN.md.
  const composed = await $.prompt.compose({ model: 'claude-opus-5-5', promptModel: 'claude-opus-5-5', surfaces: ['desktop'], tools: [], outputStyle: null, traits: [] } as never)
  expect(JSON.stringify(composed)).toContain('agent-map:plan-first')
  expect(JSON.stringify(composed)).toContain('do this before the first change')
  await $.agent.spawn({ subagentType: 'Explore', description: 'Map the API', prompt: 'x' } as never)
  t += 5_000
  await $.tool.call({ tool: 'Read', agentId: 'a1', tool_use_id: 't2', file_path: 'services/api/main.go' } as never)
  expect(midCall).toContain('● Map the API')

  // A shell command that changes PLAN.md is noticed too: the map reads the file again after it.
  plan = TWO.replace('- [~] Wire the form', '- [x] Wire the form\n- [~] Added by a script')
  await $.tool.call({ tool: 'Bash', tool_use_id: 's1', command: 'sed -i s/a/b/ PLAN.md' } as never)
  const viaShell = await $.ui.mount({ plugin: 'agent-map', surface: 'desktop', component: 'Pane', requestId: 'agent-map', props: PANE_PROPS })
  expect(JSON.stringify(await viaShell.drawn())).toContain('Added by a script')
  await viaShell.unmount()

  // With no task in progress, the first edit of a turn is answered with a reminder, the next is not.
  plan = TWO.replace('- [~] Wire the form', '- [ ] Wire the form')
  await $.tool.call({ tool: 'Edit', tool_use_id: 'p0', file_path: '/p/PLAN.md' } as never)
  const nudged = await $.tool.call({ tool: 'Edit', tool_use_id: 'p1', file_path: 'apps/web/src/page.tsx' } as never)
  expect(JSON.stringify(nudged)).toContain('no task in PLAN.md is marked in progress')
  const again = await $.tool.call({ tool: 'Edit', tool_use_id: 'p2', file_path: 'apps/web/src/page.tsx' } as never)
  expect(JSON.stringify(again)).not.toContain('no task in PLAN.md is marked in progress')

  // An edit to PLAN.md is read at once: a task ticked or added shows without a new prompt.
  plan = TWO.replace('- [~] Wire the form', '- [x] Wire the form\n- [~] Check the form')
  const sound = await $.tool.call({ tool: 'Edit', tool_use_id: 't3', file_path: '/p/PLAN.md' } as never)

  // A sound plan adds nothing to the edit's result; one the map cannot read is reported to the model.
  expect(JSON.stringify(sound)).not.toContain('cannot read')
  plan = `${plan}needs: [nowhere]\n`
  const broken = await $.tool.call({ tool: 'Edit', tool_use_id: 't4', file_path: '/p/PLAN.md' } as never)
  expect(JSON.stringify(broken)).toContain('names {#nowhere}')
  expect(JSON.stringify(await $.command.run({ command: 'map', args: 'check' } as never))).toContain('names {#nowhere}')
  plan = plan.replace('needs: [nowhere]\n', '')
  await $.tool.call({ tool: 'Edit', tool_use_id: 't5', file_path: '/p/PLAN.md' } as never)
  expect(JSON.stringify(await $.command.run({ command: 'map', args: 'check' } as never))).toContain('PLAN.md is sound')

  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ plugin: 'agent-map', surface, component: 'Pane', requestId: 'agent-map', props: PANE_PROPS })
    const drawn = JSON.stringify(await ui.drawn())
    // Task groups start folded: a line each with its count, none of the tasks' words.
    // The task in progress is listed all the same.
    for (const piece of ['Web app', 'API', 'TASKS', 'Done · 2', 'In progress · 1', 'Check the form']) expect(drawn).toContain(piece)
    for (const hidden of ['Ship the page', 'Wire the form']) expect(drawn).not.toContain(hidden)
    // The row offers only the statuses this plan has tasks in, and no card picker.
    expect(drawn).toContain('fold:done')
    for (const absent of ['fold:stuck', 'fold:todo', 'fold-card', 'Unfold']) expect(drawn).not.toContain(absent)
    // Unfolding Done shows the finished tasks on every card; In progress stays folded.
    await ui.press({ key: 'fold:done' })
    const open = JSON.stringify(await ui.drawn())
    for (const piece of ['Ship the page', 'Wire the form', 'Check the form']) expect(open).toContain(piece)
    expect(open).not.toContain('fold:working')
    await ui.press({ key: 'fold:done' })
    for (const piece of ['Web app', 'API']) expect(drawn).toContain(piece)
    // No header, legend, agent list or file tree: the map, under one row that unfolds its task groups.
    for (const gone of ['PROJECT MAP', 'AGENTS', 'FILES', 'working here now']) expect(drawn).not.toContain(gone)
    // The desktop draws the components as cards in one vector drawing; the terminal lists them.
    if (surface === 'desktop') expect(drawn).toContain('<svg xmlns')
    else expect(drawn).not.toContain('<svg xmlns')
    await ui.unmount()
  }
})

const PLAN = '# demo\n\n## Capture {#capture}\nfiles: [src/**]\n- [x] Grab the feed\n'

test('the toggle and the panel are for a project with a PLAN.md; without one, /map says how to get one', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('store.set', async () => ({ value: undefined }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  let plan = ''
  on('fs.read', async () => ({ value: plan }) as never)
  const clock = mock.clock(on)
  const asked: string[] = []
  on('prompt.submit', async (_$, e) => {
    const text = String((e as { text?: string }).text)
    asked.push(text)
    return { text } as never
  })

  const band = async () => {
    const ui = await $.ui.mount({ plugin: 'agent-map', surface: 'desktop', component: 'AbovePrompt', props: BAND_PROPS })
    const drawn = JSON.stringify(await ui.drawn())
    await ui.unmount()
    return drawn
  }
  expect(await band()).not.toContain('"label":"map"')
  const refused = await $.command.run({ command: 'map' } as never)
  expect(JSON.stringify(refused)).toContain('No PLAN.md in this project')
  expect(await band()).not.toContain('"label":"map"')

  // /map init asks the model for the plan; a PLAN.md in another format is not rewritten unasked.
  expect(JSON.stringify(await $.command.run({ command: 'map', args: 'init' } as never))).toContain('Asked Claude to write PLAN.md')
  // The prompt follows the command's own answer, from a timer.
  expect(asked.length).toBe(0)
  await clock.advance(200)
  expect(asked[0]).toContain('Write a PLAN.md at the root of this project')
  expect(asked[0]).toContain('## Name {#id}')
  plan = '# notes\n\n## Ideas\n- one\n'
  expect(JSON.stringify(await $.command.run({ command: 'map', args: 'init' } as never))).toContain('propose a conversion')
  await clock.advance(200)
  expect(asked[1]).toContain('Do not rewrite the file until I agree')

  // Once the plan is written, the same command opens the panel and the toggle appears.
  plan = PLAN
  expect(JSON.stringify(await $.command.run({ command: 'map', args: 'init' } as never))).toContain('leaves it alone')
  await clock.advance(200)
  expect(asked.length).toBe(2)
  const shown = await $.command.run({ command: 'map' } as never)
  expect(JSON.stringify(shown)).toContain('Project map shown.')
  expect(await band()).toContain('"label":"hide map"')
  expect(await band()).not.toContain('agents running')

})

test('/map refresh reads the plan again and says what it found, without showing or hiding the map', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('prompt.compose', async () => ({ sections: [] }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('store.set', async () => ({ value: undefined }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  let plan = ''
  on('fs.read', async () => ({ value: plan }) as never)
  const say = async () => JSON.stringify(await $.command.run({ command: 'map', args: 'refresh' } as never))
  expect(await say()).toContain('No PLAN.md')
  plan = '# demo\n\n## Web app {#web}\nfiles: [apps/web/**]\n- [~] Wire the form\n'
  expect(await say()).toContain('Project map read again: 1 component.')
  plan += '\n## API {#api}\nneeds: [nowhere]\nfiles: [services/api/**]\n'
  const after = await say()
  expect(after).toContain('2 components.')
  expect(after).toContain('/map check lists them')
  // Hidden it was, and hidden it stays.
  const ui = await $.ui.mount({ plugin: 'agent-map', surface: 'desktop', component: 'Pane', requestId: 'agent-map', props: { title: 'Project map', isFocused: false, bodyColumns: 120, placement: 'dock' } as never })
  expect(JSON.stringify(await ui.drawn())).toContain('API')
  await ui.unmount()
})
