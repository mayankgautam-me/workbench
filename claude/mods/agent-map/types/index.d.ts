/** One card on the map: a component of the project's PLAN.md, or the files no component claims. */
export type Area = {
  /** The component's `{#id}`. */
  path: string
  files: number
  /** From PLAN.md: the component's name, tech line, file globs, dependencies and task counts. */
  title?: string
  tech?: string
  globs?: string[]
  needs?: string[]
  links?: string[]
  kind?: string
  tasks?: { done: number; working: number; stuck: number; total: number }
  /** The component's tasks as PLAN.md words them, in order. */
  taskList?: PlanTask[]
}
export type PlanTask = { text: string; state: 'todo' | 'working' | 'done' | 'stuck' }
/** What has happened in an area this session. */
export type AreaStat = {
  reads: number
  edits: number
  lastAt: number
  lastBy: string
  /** The file last read or written here, and how many calls in a row touched it. */
  lastFile?: string
  lastFileCalls?: number
  /** The files last touched here, newest first, by project-relative path. */
  recent?: FileTouch[]
}
export type FileTouch = { file: string; reads: number; edits: number; at: number }
export type MapAgent = {
  /** The subagent's id, or `main` for the session itself. */
  id: string
  name: string
  status: 'running' | 'idle' | 'done' | 'failed'
  /** The area it last worked in. */
  area: string | null
  /** The areas it has moved through, oldest first: its trail on the map. */
  trail?: string[]
  /** What it is running now, while a tool call is in flight. */
  doing: string | null
  /** The file its call in flight names, project-relative; null between calls. */
  file?: string | null
  /** True while its latest call named no component (a command, a search): it shows on the session card. */
  loose?: boolean
  /** When it last moved from one component to another: its mark glides there for a moment. */
  movedAt?: number
  /** The tool it last called. */
  lastTool?: string | null
  tools: number
  startedAt: number | null
  endedAt: number | null
}
/** Work the session left running in the background: a shell command, a monitor, a workflow. Subagents are agents, not these. */
export type MapTask = {
  /** The engine's id for it, as its notification and TaskStop name it. */
  id: string
  /** `shell`, `monitor`, `workflow`, or the engine's own word for another kind. */
  kind: string
  /** Its command or description, in one line, secrets left out. */
  what: string
  /** The component its command names; null where it names none. */
  area: string | null
  status: 'running' | 'done' | 'failed' | 'stopped'
  startedAt: number | null
  endedAt: number | null
}

declare module 'claude-code' {
  interface PluginState {
    'agent-map': {
      root: string
      areas: Area[]
      stats: Record<string, AreaStat>
      agents: MapAgent[]
      /** Background tasks, oldest first: the running ones, and the ended ones until the next prompt. */
      tasks: MapTask[]
      /** Whether the panel is shown; null where the project has no PLAN.md, so there is no map and no toggle. */
      isOpen: boolean | null
      /** Which task groups are unfolded on the map: these statuses on every card, and every group of one card (`*` for all, '' for none). */
      tasksView: { states: PlanTask['state'][]; card: string }
    }
    /** Read only: true where the status-band mod draws the map's toggle in its own row. */
    'status-band': { carriesMap: boolean; mapPress: number }
    /** Read only: the other mods count presses of the map toggle they draw; a new count shows or hides the panel. */
    'session-tint': { mapPress: number }
  }
}
