// Presses every button the git graph would offer, against real git, in the states a repository
// is usually in:
//   node --experimental-strip-types mods/git-graph/scripts/all-buttons.mts [-v]
// For each state it reads the repository as the panel does, lists every target the panel would
// draw (each commit, each branch, remote branch and tag on it, each stash, the working tree, the
// repository) and every action offered on it, and runs each one in a copy of the repository.
// An action that is offered must run. The one exception is counted apart: git refusing before it
// changes anything, because of what is in the working tree (the panel shows that as a warning);
// the check then makes sure nothing was changed.
import { execFileSync, spawnSync } from 'node:child_process'
import { cpSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { LOG_FORMAT, REF_FORMAT, STASH_FORMAT, actionsFor, commandLine, explain, isRefusal, parseLog, parseRefs, parseStashes, parseStatus, readExtras, withStashes } from '../hooks/core.ts'

const verbose = process.argv.includes('-v')
const sh = (cwd: string, ...args: string[]) => execFileSync('git', args, { cwd, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim()
const out = (cwd: string, ...args: string[]) => spawnSync('git', args, { cwd, encoding: 'utf8' })
const write = (repo: string, file: string, text: string) => writeFileSync(join(repo, file), text)

// A repository with what a real one has: a remote, a merge in its history, a branch not yet
// merged, one already merged, a tag, a remote branch with no local one, and a stash.
const build = () => {
  const base = mkdtempSync(join(tmpdir(), 'gg-all-'))
  const origin = join(base, 'origin.git'), repo = join(base, 'repo')
  execFileSync('git', ['init', '-q', '--bare', '-b', 'main', origin])
  execFileSync('git', ['init', '-q', '-b', 'main', repo])
  sh(repo, 'config', 'user.email', 't@example.com'); sh(repo, 'config', 'user.name', 'T')
  const commit = (file: string, text: string, msg: string) => { write(repo, file, text); sh(repo, 'add', '-A'); sh(repo, 'commit', '-qm', msg) }
  commit('a.txt', 'one\n', 'first'); sh(repo, 'tag', 'v1')
  sh(repo, 'checkout', '-qb', 'side'); commit('side.txt', 'side\n', 'side work')
  sh(repo, 'checkout', '-q', 'main'); commit('b.txt', 'two\n', 'second'); sh(repo, 'branch', 'merged')
  sh(repo, 'merge', '-q', '--no-ff', '--no-edit', 'side'); sh(repo, 'branch', '-d', 'side')
  commit('c.txt', 'three\n', 'third'); sh(repo, 'tag', '-a', 'v2', '-m', 'second release')
  sh(repo, 'checkout', '-qb', 'dev', 'merged'); commit('dev.txt', 'dev\n', 'dev work')
  sh(repo, 'checkout', '-qb', 'feat', 'main'); commit('feat.txt', 'feat\n', 'feat work')
  sh(repo, 'checkout', '-q', 'main')
  sh(repo, 'remote', 'add', 'origin', origin)
  sh(repo, 'push', '-q', '-u', 'origin', 'main'); sh(repo, 'push', '-q', 'origin', 'feat'); sh(repo, 'branch', '-D', 'feat'); sh(repo, 'fetch', '-q')
  write(repo, 'a.txt', 'stashed\n'); sh(repo, 'stash', 'push', '-q')
  return base
}
const dirty = (repo: string) => { write(repo, 'b.txt', 'changed\n'); write(repo, 'new.txt', 'new\n') }
const STATES: [string, (repo: string) => void][] = [
  ['clean, on main', () => undefined],
  ['uncommitted changes, on main', dirty],
  ['on dev, which has no upstream', repo => void sh(repo, 'checkout', '-q', 'dev')],
  ['detached HEAD', repo => void sh(repo, 'checkout', '-q', '--detach', 'HEAD~1')],
  ['no remote', repo => void sh(repo, 'remote', 'remove', 'origin')],
  ['merge stopped on a conflict', repo => { sh(repo, 'checkout', '-qb', 'clash', 'merged'); write(repo, 'c.txt', 'other\n'); sh(repo, 'add', '-A'); sh(repo, 'commit', '-qm', 'clash'); sh(repo, 'checkout', '-q', 'main'); out(repo, 'merge', '--no-edit', 'clash') }],
]

// The repository as the panel reads it: the same queries, the same parsers.
const readRepo = (repo: string) => {
  const q = (...args: string[]) => out(repo, ...args)
  const ok = (r: ReturnType<typeof out>) => (r.status === 0 ? r.stdout : '')
  const commits = parseLog(ok(q('log', `--format=${LOG_FORMAT}`, '--date-order', '-n', '150', '--branches', '--tags', '--remotes', 'HEAD', '--')))
  return {
    root: repo,
    head: ok(q('rev-parse', 'HEAD')).trim() || null,
    branch: ok(q('symbolic-ref', '-q', '--short', 'HEAD')).trim() || null,
    commits: withStashes(commits, parseStashes(ok(q('stash', 'list', `--format=${STASH_FORMAT}`)))),
    refs: parseRefs(ok(q('for-each-ref', `--format=${REF_FORMAT}`))),
    changes: parseStatus(ok(q('status', '--porcelain'))),
    remotes: ok(q('remote')).split('\n').filter(Boolean),
    worktrees: [],
    hasMore: false,
    ...readExtras(args => { const r = q(...args); return { exitCode: r.status ?? 1, stdout: r.stdout } }),
  }
}
type R = ReturnType<typeof readRepo>
const targetsOf = (r: R): any[] => [
  ...((r as any).operation ? [{ kind: 'operation' }] : []),
  ...(r.changes.length ? [{ kind: 'changes' }] : []),
  ...r.commits.flatMap(c => (c.stash ? [{ kind: 'stash', name: c.stash }] : [{ kind: 'commit', hash: c.hash }, ...r.refs.filter(x => x.hash === c.hash).map(x => ({ kind: x.kind, name: x.name }))])),
  { kind: 'repo' },
]
const nameOf = (t: any, r: R) => (t.kind === 'commit' ? `commit "${r.commits.find(c => c.hash === t.hash)?.subject}"` : t.name ? `${t.kind} ${t.name}` : t.kind)

const base = build()
let ran = 0
const failures: string[] = []
const refusals: string[] = []
const snapshot = (repo: string) => `${out(repo, 'rev-parse', 'HEAD').stdout}${out(repo, 'status', '--porcelain').stdout}${out(repo, 'for-each-ref').stdout}${out(repo, 'stash', 'list').stdout}`
for (const [state, prepare] of STATES) {
  const stage = mkdtempSync(join(tmpdir(), 'gg-state-'))
  cpSync(base, stage, { recursive: true })
  const staged = join(stage, 'repo')
  if (out(staged, 'remote').stdout.trim()) sh(staged, 'remote', 'set-url', 'origin', join(stage, 'origin.git'))
  prepare(staged)
  const r = readRepo(staged)
  let n = 0
  for (const target of targetsOf(r)) {
    for (const action of actionsFor(target, r as never)) {
      const work = mkdtempSync(join(tmpdir(), 'gg-run-'))
      cpSync(stage, work, { recursive: true })
      const repo = join(work, 'repo')
      if (r.remotes.length) sh(repo, 'remote', 'set-url', 'origin', join(work, 'origin.git'))
      const commands = action.commands(action.asks ? 'new-name' : '')
      let why = ''
      const before = snapshot(repo)
      for (const args of commands) {
        const done = spawnSync('git', ['-c', 'core.editor=true', ...args], { cwd: repo, encoding: 'utf8' })
        if (done.status !== 0) { why = explain(done.stderr, done.stdout) || `exit ${done.status}`; break }
      }
      ran += 1; n += 1
      const line = `${nameOf(target, r)} → ${action.label}: ${commandLine(commands).replace(/[0-9a-f]{40}/g, h => h.slice(0, 7))}`
      if (why && isRefusal(why) && snapshot(repo) === before) refusals.push(`[${state}] ${line}\n        ${why}`)
      else if (why) failures.push(`[${state}] ${line}\n        ${why}`)
      else if (verbose) console.log(`ok    [${state}] ${line}`)
      rmSync(work, { recursive: true, force: true })
    }
  }
  console.log(`${state}: ${n} buttons`)
  rmSync(stage, { recursive: true, force: true })
}
rmSync(base, { recursive: true, force: true })
for (const f of failures) console.log(`FAIL  ${f}`)
for (const f of refusals) console.log(`refused, nothing changed  ${f}`)
console.log(`\n${ran} buttons offered: ${ran - failures.length - refusals.length} ran, ${refusals.length} were refused by git with nothing changed, ${failures.length} failed`)
process.exit(failures.length ? 1 : 0)
