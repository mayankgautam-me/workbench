/** The session's colour: its name in the palette and its hex value. */
export type Tint = { name: string; hex: string }

declare module 'claude-code' {
  interface PluginState {
    'session-tint': { tint: Tint | null; carriesMap: boolean; mapPress: number; carriesGraph: boolean; graphPress: number }
    /** Read only: whether the status-band mod is folded to one row, when that mod is installed. */
    'status-band': { isCompact: boolean }
    /** Read only: whether the agent-map mod's panel is shown, when that mod is installed. */
    'agent-map': { isOpen: boolean | null }
    /** Read only: whether the git-graph mod's panel is shown, when that mod is installed and the session is in a repository. */
    'git-graph': { isOpen: boolean | null }
  }
}
