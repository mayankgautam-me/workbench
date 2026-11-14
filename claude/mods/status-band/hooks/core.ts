// Pure formatting for the band. Nothing here touches `$`.

export type Level = 'ok' | 'warn' | 'high'

/** How full a gauge is: amber from 70%, red from 90%. */
export const levelOf = (pct: number): Level => (pct >= 90 ? 'high' : pct >= 70 ? 'warn' : 'ok')

/** Filled cells of a `cells`-wide meter: any use at all shows one cell, and it never overflows. */
export const meterFill = (pct: number, cells: number) =>
  pct <= 0 ? 0 : Math.min(cells, Math.max(1, Math.round((pct / 100) * cells)))

export const fmtTokens = (n: number) =>
  n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : n >= 1000 ? `${Math.round(n / 1000)}k` : String(n)

export const fmtUsd = (n: number) => (n >= 100 ? `$${Math.round(n)}` : `$${n.toFixed(2)}`)

export const fmtSeconds = (s: number) => (s < 60 ? `${s}s` : `${Math.floor(s / 60)}m${String(s % 60).padStart(2, '0')}s`)

/** Time left until a reset: 42m, 2h 14m, 3d 4h. Empty once it has passed. */
export const fmtUntil = (ms: number) => {
  if (ms <= 0) return ''
  const m = Math.ceil(ms / 60_000)
  if (m < 60) return `${m}m`
  const h = Math.floor(m / 60)
  if (h < 24) return `${h}h ${m % 60}m`
  return `${Math.floor(h / 24)}d ${h % 24}h`
}

const LIMIT_LABELS: Record<string, string> = { five_hour: '5-hour limit', seven_day: 'Weekly limit', spend_limit: 'Spend limit' }

export const limitLabel = (kind: string) => LIMIT_LABELS[kind] ?? kind.replace(/_/g, ' ')

export const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`

/** A name cut to `n` characters, the last one an ellipsis. */
export const shorten = (s: string, n: number) => (s.length > n ? `${s.slice(0, Math.max(0, n - 1)).trimEnd()}…` : s)

/** Obvious secrets in a command are never shown: bearer tokens, key=value credentials, URL passwords. */
export const redact = (s: string) =>
  s
    .replace(/(bearer\s+)[\w.~+/=-]+/gi, '$1•••')
    .replace(/\b([\w-]*(?:token|secret|password|passwd|api[_-]?key)[\w-]*\s*[=:]\s*)("[^"]*"|'[^']*'|\S+)/gi, '$1•••')
    .replace(/(:\/\/[^:/\s]+:)[^@\s]+@/g, '$1•••@')

const base = (path: string) => path.split('/').filter(Boolean).pop() ?? path

/**
 * What a tool call is doing, as the text shown inside `running [ ... ]`: the command for a
 * shell call, the file for a file tool, the pattern for a search, the tool's name otherwise.
 */
export const describeCall = (tool: string, args: Record<string, unknown>, max = 48) => {
  const str = (k: string) => (typeof args[k] === 'string' ? (args[k] as string) : '')
  const one = (s: string) => s.replace(/\s+/g, ' ').trim()
  let text = ''
  if (tool === 'Bash' || tool === 'PowerShell') text = redact(one(str('command')))
  else if (tool === 'Read' || tool === 'Edit' || tool === 'Write' || tool === 'NotebookEdit')
    text = `${tool} ${base(str('file_path') || str('notebook_path'))}`
  else if (tool === 'Grep' || tool === 'Glob') text = `${tool} ${one(str('pattern'))}`
  else if (tool === 'WebFetch') text = `fetch ${str('url').replace(/^https?:\/\//, '')}`
  else if (tool === 'WebSearch') text = `search ${one(str('query'))}`
  else if (tool === 'Agent') text = `agent ${one(str('description'))}`
  if (!text.trim()) text = tool.startsWith('mcp__') ? (tool.split('__').pop() ?? tool) : tool
  return shorten(text, max)
}

/**
 * The background tasks a notification says have ended, read from its text:
 * `<task-id>…</task-id>` followed by `<status>completed|failed|killed</status>`.
 */
export const endedTasks = (text: string): { id: string; isFailed: boolean }[] => {
  if (!text.includes('<task-id>')) return []
  const found: { id: string; isFailed: boolean }[] = []
  const pattern = /<task-id>([^<]+)<\/task-id>[\s\S]{0,2000}?<status>([^<]+)<\/status>/g
  for (const m of text.matchAll(pattern)) {
    const status = (m[2] ?? '').trim().toLowerCase()
    if (status === 'running' || status === 'pending') continue
    found.push({ id: (m[1] ?? '').trim(), isFailed: status !== 'completed' })
  }
  return found
}
