import { mock, test } from 'claude-code/testing'

const PANE = { title: 'Git graph', isFocused: false, bodyColumns: 118, placement: 'dock' } as never
const SEED: Record<string, string> = { c1: '9f2c4e1a', c2: '3b7d05c8', c3: 'e41a9b62', c4: '70c3f2d9', c5: 'a85e16b3', c6: '1d94c7e0', c7: '5be20f47', c8: 'c6037a1f', d1: '2a6f8d35', d2: '8e1b40c2' }
const h = (id: string) => (SEED[id] ?? id).repeat(5)
const NOW = 1_760_000_000
const c = (id: string, parents: string[], author: string, hoursAgo: number, subject: string) => `${h(id)}\x1f${parents.map(h).join(' ')}\x1f${author}\x1f${NOW - hoursAgo * 3600}\x1f${subject}\x1e`
const LOG = [
  c('c1', ['c2', 'c3'], 'Ann Rivera', 1, "Merge branch 'sensor-calibration'"),
  c('c7', ['c6'], 'Chidi Okafor', 3, 'Sign OTA images with the release key'),
  c('c3', ['c5'], 'Bo Lindqvist', 5, 'Calibrate humidity against the reference probe'),
  c('c2', ['c4'], 'Ann Rivera', 9, 'Show wind gusts on the dashboard'),
  c('c5', ['c4'], 'Bo Lindqvist', 26, 'Read the BME280 over I2C'),
  c('c4', ['c6'], 'Ann Rivera', 50, 'Batch telemetry before upload'),
  c('c6', ['c8'], 'Chidi Okafor', 75, "Add the gateway's MQTT bridge"),
  c('c8', [], 'Ann Rivera', 200, 'First reading from sensor to dashboard'),
].join('\n')
const ref = (id: string, name: string) => `${h(id)}\x1f${name}\x1f`
const REFS = [ref('c1', 'refs/heads/main'), ref('c1', 'refs/remotes/origin/main'), ref('c3', 'refs/heads/sensor-calibration'), ref('c7', 'refs/heads/feature/ota'), ref('c7', 'refs/remotes/origin/feature/ota'), ref('c4', 'refs/tags/v0.2.0'), ref('c8', 'refs/tags/v0.1.0')].join('\n')

test('demo', async ($, on) => {
  on('ui.render', async () => ({ type: 'Text', props: {}, children: [''] }) as never)
  on('session.root', async () => ({ value: '/p' }) as never)
  on('store.get', async () => ({ value: false }) as never)
  on('store.set', async () => ({ value: undefined }) as never)
  on('ui.open', async () => ({ value: { isPlaced: true } }) as never)
  const clock = mock.clock(on)
  await clock.advance(NOW * 1000)
  let refuse = false
  on('process.run', async (_$, e) => {
    const argv = ((e as { argv?: string[] }).argv ?? []).slice(3)
    const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }) as never
    const no = (stderr = '') => ({ value: { exitCode: 1, stdout: '', stderr, isStdoutTruncated: false, isStderrTruncated: false } }) as never
    if (argv[0] === 'rev-parse' && argv[1] === '--show-toplevel') return ok('/p\n')
    if (argv[0] === 'rev-parse' && argv[1] === '--abbrev-ref') return ok('origin/main\n')
    if (argv[0] === 'rev-parse' && argv[1] === '-q') return no()
    if (argv[0] === 'rev-parse') return ok(`${h('c1')}\n`)
    if (argv[0] === 'log' && argv[1] === '-1') return ok('Sign OTA images with the release key\n\nThe gateway now refuses an image whose signature does not match,\nand keeps running the one it has.\n')
    if (argv[0] === 'log') return ok(LOG)
    if (argv[0] === 'stash' && argv[1] === 'list') return ok(`${h('d1')}\x1f${h('c1')} ${h('d2')}\x1fstash@{0}\x1f${NOW - 1200}\x1fWIP on main: try a lower sample rate\x1e\n`)
    if (argv[0] === 'diff-tree' || argv[0] === 'diff') return ok('84\t6\tfirmware/src/ota.c\n31\t0\tfirmware/src/ota_verify.c\n12\t3\tgateway/internal/ota/push.go\n-\t-\tdocs/ota-flow.png\n')
    if (argv[0] === 'for-each-ref') return ok(String(argv[1]).includes('symref') ? 'origin/main\n' : REFS)
    if (argv[0] === 'symbolic-ref') return ok('main\n')
    if (argv[0] === 'status') return ok(' M dashboard/src/routes/+page.svelte\n?? notes/field-test.md\n')
    if (argv[0] === 'remote') return ok('origin\n')
    if (argv[0] === 'rev-list') return ok('0\t2\n')
    if (argv[0] === 'worktree') return ok(`worktree /p\nHEAD ${h('c1')}\nbranch refs/heads/main\n\nworktree /p/.claude/worktrees/ota-signing\nHEAD ${h('c7')}\nbranch refs/heads/feature/ota\n\nworktree /p/.claude/worktrees/dashboard-gusts\nHEAD ${h('c2')}\ndetached\n`)
    if (refuse && argv[0] === 'checkout') return no('error: Your local changes to the following files would be overwritten by checkout:\n\tdashboard/src/routes/+page.svelte\nPlease commit your changes or stash them before you switch branches.\nAborting\n')
    return ok('')
  })
  const say = (name: string, tree: unknown) => console.log(`DEMO ${name} ${JSON.stringify(tree)}`)
  await $.command.run({ command: 'graph' } as never)
  const ui = await $.ui.mount({ plugin: 'git-graph', surface: 'desktop', component: 'Pane', requestId: 'git-graph', props: PANE })
  say('graph', await ui.drawn())
  await ui.press({ key: `sel:${h('c7')}` })
  say('graph-commit', await ui.drawn())
  await ui.press({ key: `act:c:${h('c7')}:merge` })
  say('graph-confirm', await ui.drawn())
  await ui.press({ key: 'ask-cancel' })
  const band = async (name: string) => say(name, await ui.drawn())
  await ui.press({ key: 'act:repo:fetch' })
  await ui.press({ key: 'ask-run' })
  await band('toast-done')
  refuse = true
  await ui.press({ key: `act:c:${h('c7')}:checkout` })
  await ui.press({ key: 'ask-run' })
  await band('toast-refused')
  await ui.unmount()
})
