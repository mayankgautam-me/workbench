import { test } from 'claude-code/testing'

test('demo', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.measure', async (_$, e) => ({ changed: e.changed }))
  on('store.get', async () => ({ value: false }) as never)
  on('store.set', async () => ({ value: undefined }) as never)
  let t = Date.now()
  on('clock.now', async () => ({ value: t }) as never)
  let n = 0
  on('agent.spawn', async () => ({ agentId: `a${++n}`, model: 'haiku' }) as never)
  on('turn.complete', async () => ({ text: '' }) as never)
  const say = (name: string, tree: unknown) => console.log(`DEMO ${name} ${JSON.stringify(tree)}`)
  const shoot = async (name: string, columns: number, fold = false) => {
    const ui = await $.ui.mount({ plugin: 'status-band', surface: 'desktop', component: 'AbovePrompt', props: { hasSurvey: false, isWorking: true, maxRows: 12, bodyColumns: columns } as never })
    if (fold) await ui.press({ key: 'compact' })
    say(name, await ui.drawn())
    if (fold) await ui.press({ key: 'compact' })
    await ui.unmount()
  }
  let isLast = false
  on('tool.call', async () => {
    if (isLast) {
      await shoot('band', 118)
      await shoot('band-folded', 118, true)
      await shoot('band-narrow', 62)
    }
    return { result: { text: 'ok' } } as never
  })
  await $.session.measure({
    context: { window: 200_000, tokens: 84_000, percent: 42 },
    rateLimits: [
      { kind: 'five_hour', percentUsed: 38, resetsAt: new Date(t + 2.4 * 3_600_000).toISOString() },
      { kind: 'seven_day', percentUsed: 74, resetsAt: new Date(t + 3.2 * 86_400_000).toISOString() },
    ],
    cost: { usd: 1.87 },
    changed: ['context', 'rateLimits', 'cost'],
  } as never)
  await $.agent.spawn({ subagentType: 'Explore', description: 'Map the telemetry routes', prompt: 'x' } as never)
  await $.agent.spawn({ subagentType: 'general-purpose', description: 'Run the gateway tests', prompt: 'x' } as never)
  t += 21_000
  await $.tool.call({ tool: 'Read', agentId: 'a1', tool_use_id: 't1', file_path: '/p/api/internal/telemetry/routes.go' } as never)
  await $.tool.call({ tool: 'Grep', agentId: 'a1', tool_use_id: 't2', pattern: 'HandleBatch' } as never)
  t += 9_000
  isLast = true
  await $.tool.call({ tool: 'Bash', agentId: 'a2', tool_use_id: 't3', command: 'go test ./gateway/...' } as never)
})
