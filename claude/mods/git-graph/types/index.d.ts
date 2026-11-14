export type Commit = {
  hash: string
  parents: string[]
  author: string
  /** Seconds since the epoch. */
  at: number
  subject: string
  /** Set on a stash's row: its name, `stash@{0}`. */
  stash?: string
}
/** A local branch, a remote branch or a tag, and the commit it names. */
export type Ref = { kind: 'head' | 'remote' | 'tag'; name: string; hash: string }
/** Another checkout of this repository: a folder with its own HEAD, as a Claude session works in. */
export type Worktree = {
  path: string
  /** The folder's own name, which is what a session's worktree is known by. */
  name: string
  /** The commit it has checked out, and its branch (null when detached). */
  head: string
  branch: string | null
  isLocked: boolean
  /** Its folder is gone: git would prune it. */
  isPrunable: boolean
}
/** One line of `git status --porcelain`. */
export type Change = { code: string; path: string }
/** What an action is done to. */
export type Target =
  | { kind: 'commit'; hash: string }
  | { kind: 'head' | 'remote' | 'tag' | 'stash'; name: string }
  | { kind: 'changes' }
  | { kind: 'repo' }
  /** A merge, cherry-pick, revert or rebase that stopped half way. */
  | { kind: 'operation' }

/** The repository as last read. */
export type Repo = {
  root: string
  /** The checked-out commit, and the branch it is on (null when detached). */
  head: string | null
  branch: string | null
  commits: Commit[]
  refs: Ref[]
  changes: Change[]
  remotes: string[]
  /** The repository's other worktrees: not the one the session is in. */
  worktrees: Worktree[]
  /** True when the log was cut at the limit: there are older commits to load. */
  hasMore: boolean
  /** The branch the current one pulls from; null where it has none. */
  upstream: string | null
  /** How many commits the branch has that its upstream lacks, and how many the upstream has that it lacks; 0 where it has no upstream. */
  ahead: number
  behind: number
  /** A git operation that stopped half way and waits to be continued or aborted. */
  operation: 'merge' | 'cherry-pick' | 'revert' | 'rebase' | null
  /** Each remote's default branch, `origin/main`. */
  defaults: string[]
}
/** What the person chose to see. */
export type View = {
  /** A branch to show alone; '' for every branch. */
  branch: string
  showRemotes: boolean
  showTags: boolean
  showWorktrees: boolean
  find: string
  limit: number
  /** The row at the top of the commit list's own window: the list scrolls under the toolbar, which stays. */
  from: number
  /** How many lines of that row, the selected one with its card, are scrolled above the window. */
  into?: number
  /** How wide the author, age and commit columns are. */
  columns: 'compact' | 'normal' | 'wide'
}
/** An action picked and not yet run: it waits for a name, then for a yes. */
export type Pending = { target: Target; action: string; input: string; stage: 'name' | 'confirm' }
/** A message shown for a while above the prompt: what an action did, or why git refused it. */
export type Toast = { id: number; level: 'ok' | 'info' | 'warn' | 'error'; title: string; text: string }
/** One file's lines added and removed; null for a binary file. */
export type FileStat = { added: number | null; removed: number | null; path: string }
/** What was read about the selected commit: its message, and the files it changed or that differ from the commit marked to compare. */
export type Detail = { hash: string; body: string; files: FileStat[]; against: string | null }

declare module 'claude-code' {
  interface PluginState {
    'git-graph': {
      /** Whether the panel is shown; null where the session is not in a git repository. */
      isOpen: boolean | null
      repo: Repo | null
      view: View
      /** The selected commit's hash, or `*` for the uncommitted changes. */
      selected: string | null
      pending: Pending | null
      toast: Toast | null
      isBusy: boolean
      detail: Detail | null
      /** A commit marked to compare others with. */
      compare: string | null
    }
    /** Read only: the other mods count presses of the graph toggle they draw, and say that they draw it. */
    'status-band': { carriesGraph: boolean; graphPress: number }
    'session-tint': { graphPress: number }
  }
}
