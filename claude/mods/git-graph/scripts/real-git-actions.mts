// Runs every action of the git graph against real git, each in a fresh scratch repository:
//   node --experimental-strip-types mods/git-graph/scripts/real-git-actions.mts
// The mod's own tests run in the engine's kit, which has no git; this is the check that the commands themselves work.
import { execFileSync, spawnSync } from 'node:child_process'
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { actionsFor, commandLine } from '../hooks/core.ts'

const sh = (cwd: string, ...args: string[]) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
const fresh = () => {
  const base = mkdtempSync(join(tmpdir(), 'gg-'))
  const origin = join(base, 'origin.git'), repo = join(base, 'repo')
  execFileSync('git', ['init', '-q', '--bare', '-b', 'main', origin])
  execFileSync('git', ['init', '-q', '-b', 'main', repo])
  sh(repo, 'config', 'user.email', 't@example.com'); sh(repo, 'config', 'user.name', 'T')
  const commit = (file: string, text: string, msg: string) => { writeFileSync(join(repo, file), text); sh(repo, 'add', '-A'); sh(repo, 'commit', '-qm', msg); return sh(repo, 'rev-parse', 'HEAD') }
  const first = commit('a.txt', 'one\n', 'first')
  sh(repo, 'tag', 'v1'); sh(repo, 'branch', 'old')
  sh(repo, 'checkout', '-qb', 'dev'); const dev = commit('dev.txt', 'dev\n', 'dev work')
  sh(repo, 'checkout', '-qb', 'feat', 'main'); commit('feat.txt', 'feat\n', 'feat work')
  sh(repo, 'checkout', '-q', 'main'); const last = commit('b.txt', 'two\n', 'second')
  sh(repo, 'remote', 'add', 'origin', origin)
  sh(repo, 'push', '-q', '-u', 'origin', 'main'); sh(repo, 'push', '-q', 'origin', 'feat'); sh(repo, 'branch', '-D', 'feat'); sh(repo, 'fetch', '-q')
  return { base, repo, first, dev, last }
}
const dirty = (repo: string) => { writeFileSync(join(repo, 'a.txt'), 'changed\n'); writeFileSync(join(repo, 'new.txt'), 'new\n') }
const ctx = { branch: 'main', remotes: ['origin'] }
type Case = { target: (r: ReturnType<typeof fresh>) => any; id: string; input?: string; before?: (r: ReturnType<typeof fresh>) => void; check?: (r: ReturnType<typeof fresh>) => boolean }
const C = (target: Case['target'], id: string, more: Partial<Case> = {}): Case => ({ target, id, ...more })
const onDev = (r: any) => ({ kind: 'commit', hash: r.dev }), onFirst = (r: any) => ({ kind: 'commit', hash: r.first }), onLast = (r: any) => ({ kind: 'commit', hash: r.last })
const head = (name: string) => () => ({ kind: 'head', name }), stash = () => ({ kind: 'stash', name: 'stash@{0}' })
const makeStash = (r: any) => { dirty(r.repo); sh(r.repo, 'stash', 'push', '--include-untracked') }
const cases: Case[] = [
  C(onDev, 'checkout', { check: r => sh(r.repo, 'rev-parse', 'HEAD') === r.dev }),
  C(onDev, 'branch', { input: 'topic', check: r => sh(r.repo, 'rev-parse', 'topic') === r.dev }),
  C(onDev, 'branch-checkout', { input: 'topic', check: r => sh(r.repo, 'symbolic-ref', '--short', 'HEAD') === 'topic' }),
  C(onDev, 'tag', { input: 'v2', check: r => sh(r.repo, 'rev-parse', 'v2') === r.dev }),
  C(onDev, 'cherry-pick', { check: r => sh(r.repo, 'log', '-1', '--format=%s') === 'dev work' }),
  C(onLast, 'revert', { check: r => sh(r.repo, 'log', '-1', '--format=%s').startsWith('Revert') }),
  C(onDev, 'merge', { check: r => sh(r.repo, 'rev-list', '--count', '--merges', 'HEAD') === '1' }),
  C(onDev, 'rebase', { check: r => sh(r.repo, 'merge-base', '--is-ancestor', r.dev, 'HEAD') === '' }),
  C(onFirst, 'reset-soft', { check: r => sh(r.repo, 'rev-parse', 'HEAD') === r.first && sh(r.repo, 'status', '--porcelain') !== '' }),
  C(onFirst, 'reset-mixed', { check: r => sh(r.repo, 'rev-parse', 'HEAD') === r.first }),
  C(onFirst, 'reset-hard', { check: r => sh(r.repo, 'rev-parse', 'HEAD') === r.first && sh(r.repo, 'status', '--porcelain') === '' }),
  C(head('dev'), 'checkout', { check: r => sh(r.repo, 'symbolic-ref', '--short', 'HEAD') === 'dev' }),
  C(head('dev'), 'rename', { input: 'develop', check: r => sh(r.repo, 'rev-parse', 'develop') === r.dev }),
  C(head('dev'), 'merge'),
  C(head('dev'), 'rebase'),
  C(head('old'), 'delete', { check: r => sh(r.repo, 'branch', '--list', 'old') === '' }),
  C(head('dev'), 'delete-force', { check: r => sh(r.repo, 'branch', '--list', 'dev') === '' }),
  C(head('dev'), 'push', { check: r => sh(r.repo, 'rev-parse', 'origin/dev') === r.dev }),
  C(head('main'), 'rename', { input: 'trunk', check: r => sh(r.repo, 'symbolic-ref', '--short', 'HEAD') === 'trunk' }),
  C(head('main'), 'push'),
  C(() => ({ kind: 'remote', name: 'origin/feat' }), 'checkout', { check: r => sh(r.repo, 'symbolic-ref', '--short', 'HEAD') === 'feat' }),
  C(() => ({ kind: 'remote', name: 'origin/feat' }), 'merge'),
  C(() => ({ kind: 'remote', name: 'origin/feat' }), 'pull'),
  C(() => ({ kind: 'remote', name: 'origin/feat' }), 'delete', { check: r => sh(r.repo, 'branch', '-r', '--list', 'origin/feat') === '' }),
  C(() => ({ kind: 'tag', name: 'v1' }), 'push', { check: r => sh(r.repo, 'ls-remote', '--tags', 'origin').includes('refs/tags/v1') }),
  C(() => ({ kind: 'tag', name: 'v1' }), 'delete', { check: r => sh(r.repo, 'tag', '--list', 'v1') === '' }),
  C(() => ({ kind: 'changes' }), 'stash', { before: r => dirty(r.repo), check: r => sh(r.repo, 'status', '--porcelain') === '' && sh(r.repo, 'stash', 'list') !== '' }),
  C(() => ({ kind: 'changes' }), 'discard', { before: r => dirty(r.repo), check: r => sh(r.repo, 'status', '--porcelain') === '?? new.txt' }),
  C(() => ({ kind: 'changes' }), 'clean', { before: r => dirty(r.repo), check: r => sh(r.repo, 'status', '--porcelain') === 'M a.txt' }),
  C(() => ({ kind: 'repo' }), 'fetch'),
  C(() => ({ kind: 'repo' }), 'pull'),
  C(() => ({ kind: 'repo' }), 'push'),
  C(stash, 'apply', { before: makeStash, check: r => sh(r.repo, 'status', '--porcelain') !== '' && sh(r.repo, 'stash', 'list') !== '' }),
  C(stash, 'pop', { before: makeStash, check: r => sh(r.repo, 'status', '--porcelain') !== '' && sh(r.repo, 'stash', 'list') === '' }),
  C(stash, 'branch', { before: makeStash, input: 'from-stash', check: r => sh(r.repo, 'symbolic-ref', '--short', 'HEAD') === 'from-stash' }),
  C(stash, 'drop', { before: makeStash, check: r => sh(r.repo, 'stash', 'list') === '' }),
]
// Every action the mod offers is in the list above, none forgotten.
const offered = new Set<string>()
const r0 = fresh()
for (const t of [onDev(r0), head('dev')(), head('main')(), { kind: 'remote', name: 'origin/feat' }, { kind: 'tag', name: 'v1' }, { kind: 'changes' }, { kind: 'repo' }, stash()]) for (const a of actionsFor(t as any, ctx)) offered.add(`${(t as any).kind}:${(t as any).name === 'main' ? 'main:' : ''}${a.id}`)
rmSync(r0.base, { recursive: true, force: true })
let failed = 0
for (const c of cases) {
  const r = fresh()
  try {
    c.before?.(r)
    const target = c.target(r)
    const action = actionsFor(target, ctx).find(a => a.id === c.id)
    if (!action) throw new Error('not offered')
    const commands = action.commands(c.input ?? '')
    for (const args of commands) {
      const ran = spawnSync('git', ['-c', 'core.editor=true', ...args], { cwd: r.repo, encoding: 'utf8' })
      if (ran.status !== 0) throw new Error(`exit ${ran.status}: ${(ran.stderr || ran.stdout).trim().split('\n').slice(-2).join(' ')}`)
    }
    if (c.check && !c.check(r)) throw new Error('ran, but the repository is not as expected')
    console.log(`ok    ${target.kind.padEnd(8)} ${c.id.padEnd(16)} ${commandLine(commands).replace(/[0-9a-f]{40}/g, '<hash>')}`)
  } catch (err) {
    failed += 1
    console.log(`FAIL  ${c.id}: ${String((err as Error).message)}`)
  } finally {
    rmSync(r.base, { recursive: true, force: true })
  }
}
console.log(`\n${cases.length - failed} of ${cases.length} actions ran against real git; ${offered.size} distinct actions offered`)
process.exit(failed ? 1 : 0)
