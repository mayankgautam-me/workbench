import { expect, test } from 'claude-code/testing'

const PANE_PROPS = { title: 'Project map', isFocused: false, bodyColumns: 120, placement: 'dock' } as never
const PLAN = '# demo\n\n## Web app {#web}\nfiles: [apps/web/**]\n- [~] Wire the form\n\n## API {#api}\nneeds: [web]\nfiles: [services/api/**]\n'

test('what the session leaves running in the background is on the map until the prompt after it ends', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('prompt.compose', async () => ({ sections: [] }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('store.set', async () => ({ value: undefined }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  on('fs.read', async () => ({ value: PLAN }) as never)
  let t = 1_000_000
  on('clock.now', async () => ({ value: t }) as never)
  on('turn.complete', async () => ({ text: '' }) as never)
  on('prompt.submit', async (_$, e) => ({ text: (e as { text: string }).text }) as never)
  on('tool.call', async (_$, e) => {
    const id = (e as { tool_use_id?: string }).tool_use_id
    if (id === 'dev') return { result: { stdout: '', stderr: '', interrupted: false, backgroundTaskId: 'b1' } } as never
    if (id === 'watch') return { result: { taskId: 'm1', timeoutMs: 0 } } as never
    return { result: { text: 'ok' } } as never
  })
  const draw = async (surface: 'desktop' | 'terminal') => {
    const ui = await $.ui.mount({ plugin: 'agent-map', surface, component: 'Pane', requestId: 'agent-map', props: PANE_PROPS })
    const drawn = JSON.stringify(await ui.drawn())
    await ui.unmount()
    return drawn
  }

  await $.command.run({ command: 'map' } as never)
  // A shell command sent to the background, naming a path in the web app; a monitor naming none.
  await $.tool.call({ tool: 'Bash', tool_use_id: 'dev', command: 'npm --prefix apps/web run dev', run_in_background: true } as never)
  await $.tool.call({ tool: 'Monitor', tool_use_id: 'watch', description: 'gateway log', command: 'tail -f /var/log/gateway.log', timeout_ms: 1000 } as never)
  await $.tool.call({ tool: 'Bash', tool_use_id: 'plain', command: 'ls' } as never)
  t += 125_000
  const running = await draw('desktop')
  // On the session card with where it works, and on the web app's card.
  for (const piece of ['>shell<', 'npm --prefix apps/web run dev', '2 min  ·  in Web app', '>monitor<', 'tail -f /var/log/gateway.log']) expect(running).toContain(piece)
  expect(running.split('npm --prefix apps/web run dev').length - 1).toBe(2)
  expect(running.split('tail -f /var/log/gateway.log').length - 1).toBe(1)
  const listed = await draw('terminal')
  for (const piece of ['▢ shell', 'npm --prefix apps/web run dev', '2 min · in Web app', '▢ monitor']) expect(listed).toContain(piece)

  // Stopped: it says so, and leaves the component's card.
  await $.tool.call({ tool: 'TaskStop', tool_use_id: 'stop', task_id: 'b1' } as never)
  const stopped = await draw('desktop')
  expect(stopped).toContain('stopped after 2 min')
  expect(stopped.split('npm --prefix apps/web run dev').length - 1).toBe(1)

  // The next prompt clears what has ended; the monitor still runs.
  await $.prompt.submit({ text: 'carry on' } as never)
  const after = await draw('desktop')
  expect(after).not.toContain('npm --prefix apps/web run dev')
  expect(after).toContain('tail -f /var/log/gateway.log')
})
