export type Limit = { kind: string; pct: number; resetsAt: string | null }
export type Usage = {
  pct: number | null
  tokens: number | null
  window: number | null
  usd: number | null
  limits: Limit[]
  /** True while the context figures are the local estimate made on open, before any reply. */
  isEstimated?: boolean
}
export type Turn = { seconds: number; tools: number; edits: number }
export type Agent = {
  id: string
  name: string
  status: 'running' | 'done' | 'failed'
  /** What it is running now, while a tool call is in flight: the command, file or tool name. */
  tool: string | null
  tools: number
  /** Null when the agent was already running before the band loaded. */
  startedAt: number | null
  endedAt: number | null
}
/** A background task that is not a subagent: a shell command, a monitor, a workflow. */
export type Task = {
  id: string
  kind: string
  label: string
  status: 'running' | 'done' | 'failed'
  startedAt: number | null
  endedAt: number | null
}

declare module 'claude-code' {
  interface PluginState {
    'status-band': { usage: Usage; last: Turn | null; agents: Agent[]; tasks: Task[]; isHidden: boolean; isCompact: boolean; carriesMap: boolean; mapPress: number; carriesGraph: boolean; graphPress: number }
    /** Read only: the session-tint mod's colour for this session, when that mod is installed. */
    'session-tint': { tint: { name: string; hex: string } | null; carriesMap: boolean; carriesGraph: boolean }
    /** Read only: whether the agent-map mod's panel is shown, when that mod is installed. */
    'agent-map': { isOpen: boolean | null }
    /** Read only: whether the git-graph mod's panel is shown, when that mod is installed and the session is in a repository. */
    'git-graph': { isOpen: boolean | null }
  }
}
