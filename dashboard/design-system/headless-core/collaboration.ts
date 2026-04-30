/**
 * CollaborationCursor — multi-agent file presence + conflict detection
 * (RFC 0010).
 *
 * Thin layer over AgentPresenceManager (RFC 0008). AgentPresence already
 * carries cursor: { line, column } and currentFile per agent; this module
 * adds:
 *   - Selection state (range edits) — kept here, NOT in AgentPresence.
 *   - File-scoped active-cursor lookup (`activeAgentsInFile`).
 *   - Overlap-zone conflict detection (`conflictsInFile`).
 *   - SR conflict announcements with role-alert urgency.
 *
 * MVP scope (RFC 0010 §3, §4, §5, §6):
 *   - Conflict zone = [cursor.line - radius, cursor.line + radius],
 *     default radius 1 (3 lines per cursor).
 *   - Selections expand to [sel.line - radius, sel.end.line + radius].
 *   - Sweep groups overlapping zones into a single FileConflict; merge
 *     contiguous overlap chains.
 *   - Per-file emit only when that file's cursor list actually changes.
 *   - Conflict subscriber emits only on conflict-set delta — no spam
 *     during continuous typing within an existing conflict.
 *   - announceConflict text formats per RFC §6 (2 vs 3+ agents).
 *
 * Out of scope (deferred per RFC 0010 §10):
 *   - Operational Transform synchronization (consumer-side).
 *   - Cursor color rendering (colorSlot already on Agent — consumer paints).
 *   - Multi-file conflict aggregation (one file at a time).
 *   - Debouncing during continuous typing (consumer wraps if needed).
 */

import type { Agent, AgentPresenceManager } from './agent-presence'

export interface CursorPosition {
  readonly line: number
  readonly column: number
}

export interface Selection {
  readonly line: number
  readonly column: number
  readonly end: CursorPosition
}

export interface AgentCursor {
  readonly agent: Agent
  readonly file: string
  readonly position: CursorPosition
  readonly selection?: Selection
}

export interface FileConflict {
  readonly file: string
  readonly lineFrom: number
  readonly lineTo: number
  readonly agents: ReadonlyArray<Agent>
}

export interface CollaborationOptions {
  presence: AgentPresenceManager
  conflictRadius?: number
}

export interface ConflictAnnouncement {
  readonly text: string
  readonly assertive: true
}

export interface CollaborationManager {
  activeAgentsInFile(file: string): ReadonlyArray<AgentCursor>
  conflictsInFile(file: string): ReadonlyArray<FileConflict>
  setSelection(agentId: string, file: string, sel: Selection): void
  clearSelection(agentId: string): void
  announceConflict(conflict: FileConflict): ConflictAnnouncement

  subscribeFile(
    file: string,
    listener: (cursors: ReadonlyArray<AgentCursor>) => void,
  ): () => void

  subscribeConflicts(
    listener: (conflicts: ReadonlyArray<FileConflict>) => void,
  ): () => void

  /** Tear down the AgentPresence subscription. Test/cleanup helper. */
  dispose(): void
}

const DEFAULT_RADIUS = 1

function basename(path: string): string {
  const parts = path.split('/')
  return parts[parts.length - 1] ?? path
}

function cursorEqual(a: AgentCursor, b: AgentCursor): boolean {
  if (a.agent.id !== b.agent.id) return false
  if (a.file !== b.file) return false
  if (a.position.line !== b.position.line) return false
  if (a.position.column !== b.position.column) return false
  const sa = a.selection
  const sb = b.selection
  if (sa === undefined && sb === undefined) return true
  if (sa === undefined || sb === undefined) return false
  return (
    sa.line === sb.line &&
    sa.column === sb.column &&
    sa.end.line === sb.end.line &&
    sa.end.column === sb.end.column
  )
}

function cursorListEqual(
  a: ReadonlyArray<AgentCursor>,
  b: ReadonlyArray<AgentCursor>,
): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i += 1) {
    if (!cursorEqual(a[i]!, b[i]!)) return false
  }
  return true
}

function conflictEqual(a: FileConflict, b: FileConflict): boolean {
  if (a.file !== b.file) return false
  if (a.lineFrom !== b.lineFrom) return false
  if (a.lineTo !== b.lineTo) return false
  if (a.agents.length !== b.agents.length) return false
  const aIds = a.agents.map((x) => x.id).sort()
  const bIds = b.agents.map((x) => x.id).sort()
  for (let i = 0; i < aIds.length; i += 1) {
    if (aIds[i] !== bIds[i]) return false
  }
  return true
}

function conflictListEqual(
  a: ReadonlyArray<FileConflict>,
  b: ReadonlyArray<FileConflict>,
): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i += 1) {
    if (!conflictEqual(a[i]!, b[i]!)) return false
  }
  return true
}

export function createCollaborationManager(
  opts: CollaborationOptions,
): CollaborationManager {
  const presence = opts.presence
  const conflictRadius = opts.conflictRadius ?? DEFAULT_RADIUS

  const selections = new Map<string, Selection>()

  const fileListeners = new Map<
    string,
    Set<(cursors: ReadonlyArray<AgentCursor>) => void>
  >()
  const conflictListeners = new Set<
    (conflicts: ReadonlyArray<FileConflict>) => void
  >()

  const lastFileCursors = new Map<string, ReadonlyArray<AgentCursor>>()
  const lastConflicts = new Map<string, ReadonlyArray<FileConflict>>()

  function activeAgentsInFile(file: string): ReadonlyArray<AgentCursor> {
    const out: AgentCursor[] = []
    for (const agent of presence.withinFile(file)) {
      if (agent.cursor === undefined) continue
      const cursor: AgentCursor = {
        agent,
        file,
        position: agent.cursor,
        selection: selections.get(agent.id),
      }
      out.push(Object.freeze(cursor))
    }
    return Object.freeze(out)
  }

  function conflictsInFile(file: string): ReadonlyArray<FileConflict> {
    const cursors = activeAgentsInFile(file)
    if (cursors.length < 2) return Object.freeze([])

    const zones = cursors.map((c) => {
      const sel = c.selection
      const baseLineFrom = sel !== undefined
        ? Math.min(sel.line, sel.end.line)
        : c.position.line
      const baseLineTo = sel !== undefined
        ? Math.max(sel.line, sel.end.line)
        : c.position.line
      return {
        agent: c.agent,
        from: baseLineFrom - conflictRadius,
        to: baseLineTo + conflictRadius,
      }
    })
    zones.sort((a, b) => a.from - b.from)

    const conflicts: FileConflict[] = []
    let cluster: typeof zones = []
    let clusterMaxTo = -Infinity
    for (const z of zones) {
      if (cluster.length === 0 || z.from <= clusterMaxTo) {
        cluster.push(z)
        clusterMaxTo = Math.max(clusterMaxTo, z.to)
      } else {
        if (cluster.length >= 2) conflicts.push(makeConflict(file, cluster))
        cluster = [z]
        clusterMaxTo = z.to
      }
    }
    if (cluster.length >= 2) conflicts.push(makeConflict(file, cluster))
    return Object.freeze(conflicts)
  }

  function makeConflict(file: string, cluster: ReadonlyArray<{ agent: Agent; from: number; to: number }>): FileConflict {
    let lineFrom = Infinity
    let lineTo = -Infinity
    const agents: Agent[] = []
    for (const z of cluster) {
      if (z.from < lineFrom) lineFrom = z.from
      if (z.to > lineTo) lineTo = z.to
      agents.push(z.agent)
    }
    return Object.freeze({
      file,
      lineFrom,
      lineTo,
      agents: Object.freeze(agents),
    })
  }

  function announceConflict(conflict: FileConflict): ConflictAnnouncement {
    const names = conflict.agents.map((a) => a.name)
    let participants: string
    if (names.length === 2) {
      participants = `${names[0]} and ${names[1]}`
    } else if (names.length >= 3) {
      const others = names.length - 2
      const tail = others === 1 ? '1 other' : `${others} others`
      participants = `${names[0]}, ${names[1]}, and ${tail}`
    } else {
      // Should not happen — conflict requires ≥ 2 agents.
      participants = names.join(', ')
    }
    const lines =
      conflict.lineFrom === conflict.lineTo
        ? `line ${conflict.lineFrom}`
        : `lines ${conflict.lineFrom}-${conflict.lineTo}`
    return Object.freeze({
      text: `Editing conflict between ${participants} on ${lines} of ${basename(conflict.file)}`,
      assertive: true,
    })
  }

  function emitFile(file: string): void {
    const set = fileListeners.get(file)
    if (set === undefined || set.size === 0) return
    const cursors = activeAgentsInFile(file)
    const last = lastFileCursors.get(file) ?? []
    if (cursorListEqual(last, cursors)) return
    lastFileCursors.set(file, cursors)
    for (const l of set) l(cursors)
  }

  function emitConflictsForFile(file: string): boolean {
    const next = conflictsInFile(file)
    const last = lastConflicts.get(file) ?? []
    if (conflictListEqual(last, next)) return false
    lastConflicts.set(file, next)
    return true
  }

  function emitConflictsAggregate(): void {
    const all: FileConflict[] = []
    for (const cs of lastConflicts.values()) {
      for (const c of cs) all.push(c)
    }
    const frozen = Object.freeze(all)
    for (const l of conflictListeners) l(frozen)
  }

  // Track previous per-agent cursor + file to compute affected files.
  const lastAgentSeen = new Map<
    string,
    { file: string | undefined; line: number | undefined; column: number | undefined }
  >()

  function affectedFilesFromSnapshot(snapshot: ReadonlyArray<Agent>): Set<string> {
    const affected = new Set<string>()
    const seenIds = new Set<string>()
    for (const agent of snapshot) {
      seenIds.add(agent.id)
      const prev = lastAgentSeen.get(agent.id)
      const curFile = agent.currentFile
      const curLine = agent.cursor?.line
      const curColumn = agent.cursor?.column
      const changed =
        prev === undefined ||
        prev.file !== curFile ||
        prev.line !== curLine ||
        prev.column !== curColumn
      if (changed) {
        if (prev?.file !== undefined) affected.add(prev.file)
        if (curFile !== undefined) affected.add(curFile)
      }
      lastAgentSeen.set(agent.id, {
        file: curFile,
        line: curLine,
        column: curColumn,
      })
    }
    // Removed agents.
    for (const id of Array.from(lastAgentSeen.keys())) {
      if (!seenIds.has(id)) {
        const prev = lastAgentSeen.get(id)
        if (prev?.file !== undefined) affected.add(prev.file)
        lastAgentSeen.delete(id)
      }
    }
    return affected
  }

  const dispose = presence.subscribe((snapshot) => {
    const affected = affectedFilesFromSnapshot(snapshot)
    let conflictsChanged = false
    for (const file of affected) {
      emitFile(file)
      if (emitConflictsForFile(file)) conflictsChanged = true
    }
    if (conflictsChanged) emitConflictsAggregate()
  })

  return {
    activeAgentsInFile,
    conflictsInFile,
    announceConflict,

    setSelection(agentId: string, file: string, sel: Selection): void {
      selections.set(agentId, sel)
      emitFile(file)
      if (emitConflictsForFile(file)) emitConflictsAggregate()
    },

    clearSelection(agentId: string): void {
      const had = selections.has(agentId)
      if (!had) return
      const a = presence.agents.get(agentId)
      const file = a?.currentFile
      selections.delete(agentId)
      if (file !== undefined) {
        emitFile(file)
        if (emitConflictsForFile(file)) emitConflictsAggregate()
      }
    },

    subscribeFile(
      file: string,
      listener: (cursors: ReadonlyArray<AgentCursor>) => void,
    ): () => void {
      let set = fileListeners.get(file)
      if (set === undefined) {
        set = new Set()
        fileListeners.set(file, set)
      }
      set.add(listener)
      return () => {
        set!.delete(listener)
        if (set!.size === 0) fileListeners.delete(file)
      }
    },

    subscribeConflicts(
      listener: (conflicts: ReadonlyArray<FileConflict>) => void,
    ): () => void {
      conflictListeners.add(listener)
      return () => {
        conflictListeners.delete(listener)
      }
    },

    dispose,
  }
}
