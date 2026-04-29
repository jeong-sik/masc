/**
 * AgentPresenceManager — canonical agent registry (RFC 0008).
 *
 * Replaces today's drift across keeper-card / agent-monitor / lifeline /
 * composer mention popover where each surface owns its own roster cache.
 * One manager owns id / name / sigil / colorSlot / state / cursor /
 * heartbeat for every agent; consumers subscribe and render.
 *
 * MVP scope (RFC 0008 §3, §4, §5):
 *   - 6-state model (idle/working/thinking/waiting_for_human/error/completed)
 *   - register / unregister / has / updateState / updateCursor /
 *     clearCursor / heartbeat
 *   - byState / withinFile queries
 *   - subscribe (snapshot) and subscribeAgent (per-agent listener)
 *   - announceStateChange returning SR text per transition (assertive
 *     for *->error, polite otherwise)
 *   - deriveSigil with collision suffix policy (NC / NC² / NC³ via
 *     superscript digits)
 *   - kSlot deterministic FNV-1a mod 12 mapping
 *   - reducedMotion getter (consumer keys off animation; primitive is
 *     animation-agnostic)
 *
 * Out of scope (RFC 0008 §10):
 *   - Network sync (consumer adapter calls update*)
 *   - RBAC / permission filtering
 *   - Stale heartbeat -> synthetic 'stalled' state (consumer-side
 *     based on idleMs)
 */

export type AgentState =
  | 'idle'
  | 'working'
  | 'thinking'
  | 'waiting_for_human'
  | 'error'
  | 'completed'

export type AgentColorSlot =
  | 1
  | 2
  | 3
  | 4
  | 5
  | 6
  | 7
  | 8
  | 9
  | 10
  | 11
  | 12

export interface AgentSigil {
  readonly text: string
  readonly suffix?: string
}

export interface AgentDescriptor {
  readonly id: string
  readonly name: string
  readonly sigil: AgentSigil
  readonly colorSlot: AgentColorSlot
}

export interface AgentRuntimeState {
  readonly state: AgentState
  readonly currentFile?: string
  readonly cursor?: { readonly line: number; readonly column: number }
  readonly stateChangedAt: string
  readonly idleMs?: number
}

export interface Agent extends AgentDescriptor, AgentRuntimeState {}

export interface AgentPresenceOptions {
  initialAgents?: ReadonlyArray<AgentDescriptor>
  reducedMotion?: () => boolean
  sigilDisambiguate?: (
    candidate: AgentSigil,
    existing: ReadonlyArray<AgentSigil>,
  ) => AgentSigil
}

export interface StateChangeAnnouncement {
  readonly text: string
  readonly assertive: boolean
}

export interface AgentPresenceManager {
  readonly agents: ReadonlyMap<string, Agent>

  register(agent: AgentDescriptor): void
  unregister(id: string): void
  has(id: string): boolean

  updateState(id: string, state: AgentState): void
  updateCursor(id: string, file: string, line: number, column: number): void
  clearCursor(id: string): void
  heartbeat(id: string): void

  byState(state: AgentState): ReadonlyArray<Agent>
  withinFile(file: string): ReadonlyArray<Agent>

  subscribe(listener: (snapshot: ReadonlyArray<Agent>) => void): () => void
  subscribeAgent(id: string, listener: (agent: Agent) => void): () => void

  announceStateChange(id: string, prevState: AgentState): StateChangeAnnouncement | null

  reducedMotion(): boolean
}

const SUPERSCRIPT_DIGITS = ['¹', '²', '³', '⁴', '⁵', '⁶', '⁷', '⁸', '⁹']

function defaultDisambiguate(
  candidate: AgentSigil,
  existing: ReadonlyArray<AgentSigil>,
): AgentSigil {
  let count = 0
  for (const e of existing) {
    if (e.text === candidate.text) count += 1
  }
  if (count === 0) return candidate
  // Use superscript digit per RFC 0008 §6 default.
  const suffix = SUPERSCRIPT_DIGITS[count] ?? `^${count + 1}`
  return Object.freeze({ text: candidate.text, suffix })
}

/** FNV-1a hash mod 12, slots numbered 1..12. */
export function kSlot(id: string): AgentColorSlot {
  let hash = 0x811c9dc5
  for (let i = 0; i < id.length; i += 1) {
    hash ^= id.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193)
  }
  // imul keeps it i32; coerce to unsigned via >>> 0
  const unsigned = hash >>> 0
  const slot = (unsigned % 12) + 1
  return slot as AgentColorSlot
}

export function deriveSigil(name: string): AgentSigil {
  const cleaned = name.replace(/[^A-Za-z]/g, '').toUpperCase()
  const text = cleaned.length >= 2 ? cleaned.slice(0, 2) : cleaned.padEnd(2, '?')
  return Object.freeze({ text })
}

function nowIso(): string {
  return new Date().toISOString()
}

export function createAgentPresenceManager(
  opts?: AgentPresenceOptions,
): AgentPresenceManager {
  const reducedMotionFn = opts?.reducedMotion ?? (() => false)
  const disambiguate = opts?.sigilDisambiguate ?? defaultDisambiguate

  const map = new Map<string, Agent>()
  const listeners = new Set<(snapshot: ReadonlyArray<Agent>) => void>()
  const perAgent = new Map<string, Set<(agent: Agent) => void>>()

  function snapshot(): ReadonlyArray<Agent> {
    return Object.freeze([...map.values()])
  }

  function emit(): void {
    const snap = snapshot()
    for (const listener of listeners) listener(snap)
  }

  function emitAgent(id: string): void {
    const agent = map.get(id)
    if (agent === undefined) return
    const set = perAgent.get(id)
    if (set === undefined) return
    for (const listener of set) listener(agent)
  }

  function existingSigils(excludeId?: string): ReadonlyArray<AgentSigil> {
    const out: AgentSigil[] = []
    for (const a of map.values()) {
      if (a.id === excludeId) continue
      out.push(a.sigil)
    }
    return out
  }

  function setAgent(next: Agent): void {
    map.set(next.id, next)
    emit()
    emitAgent(next.id)
  }

  // Bootstrap initial roster.
  if (opts?.initialAgents !== undefined) {
    for (const desc of opts.initialAgents) {
      const sigil = disambiguate(desc.sigil, existingSigils(desc.id))
      const agent: Agent = Object.freeze({
        ...desc,
        sigil,
        state: 'idle',
        stateChangedAt: nowIso(),
      })
      map.set(agent.id, agent)
    }
  }

  return {
    get agents() {
      return map as ReadonlyMap<string, Agent>
    },

    register(desc: AgentDescriptor): void {
      const sigil = disambiguate(desc.sigil, existingSigils(desc.id))
      const prior = map.get(desc.id)
      const agent: Agent = Object.freeze({
        ...desc,
        sigil,
        state: prior?.state ?? 'idle',
        currentFile: prior?.currentFile,
        cursor: prior?.cursor,
        stateChangedAt: prior?.stateChangedAt ?? nowIso(),
        idleMs: prior?.idleMs,
      })
      setAgent(agent)
    },

    unregister(id: string): void {
      if (!map.has(id)) return
      map.delete(id)
      perAgent.delete(id)
      emit()
    },

    has(id: string): boolean {
      return map.has(id)
    },

    updateState(id: string, state: AgentState): void {
      const prior = map.get(id)
      if (prior === undefined) return
      if (prior.state === state) return
      const next: Agent = Object.freeze({
        ...prior,
        state,
        stateChangedAt: nowIso(),
      })
      setAgent(next)
    },

    updateCursor(id: string, file: string, line: number, column: number): void {
      const prior = map.get(id)
      if (prior === undefined) return
      const next: Agent = Object.freeze({
        ...prior,
        currentFile: file,
        cursor: Object.freeze({ line, column }),
      })
      setAgent(next)
    },

    clearCursor(id: string): void {
      const prior = map.get(id)
      if (prior === undefined) return
      // omit currentFile / cursor by destructuring
      const { currentFile: _f, cursor: _c, ...rest } = prior
      const next = Object.freeze({ ...rest } as Agent)
      setAgent(next)
    },

    heartbeat(id: string): void {
      const prior = map.get(id)
      if (prior === undefined) return
      const next: Agent = Object.freeze({ ...prior, idleMs: 0 })
      setAgent(next)
    },

    byState(state: AgentState): ReadonlyArray<Agent> {
      const out: Agent[] = []
      for (const a of map.values()) {
        if (a.state === state) out.push(a)
      }
      return Object.freeze(out)
    },

    withinFile(file: string): ReadonlyArray<Agent> {
      const out: Agent[] = []
      for (const a of map.values()) {
        if (a.currentFile === file) out.push(a)
      }
      return Object.freeze(out)
    },

    subscribe(listener: (snapshot: ReadonlyArray<Agent>) => void): () => void {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },

    subscribeAgent(id: string, listener: (agent: Agent) => void): () => void {
      let set = perAgent.get(id)
      if (set === undefined) {
        set = new Set()
        perAgent.set(id, set)
      }
      set.add(listener)
      return () => {
        const s = perAgent.get(id)
        if (s !== undefined) s.delete(listener)
      }
    },

    announceStateChange(
      id: string,
      _prevState: AgentState,
    ): StateChangeAnnouncement | null {
      const agent = map.get(id)
      if (agent === undefined) return null
      const name = agent.name
      switch (agent.state) {
        case 'working':
          return Object.freeze({ text: `${name} is now working`, assertive: false })
        case 'waiting_for_human':
          return Object.freeze({
            text: `${name} is waiting for your input`,
            assertive: false,
          })
        case 'error':
          return Object.freeze({ text: `${name} reported an error`, assertive: true })
        case 'completed':
          return Object.freeze({ text: `${name} completed`, assertive: false })
        case 'thinking':
        case 'idle':
        default:
          return null
      }
    },

    reducedMotion(): boolean {
      return reducedMotionFn()
    },
  }
}
