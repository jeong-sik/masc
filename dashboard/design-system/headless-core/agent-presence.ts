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
 *   - 15 color slots (12 keeper + 3 reserve)
 *   - Ephemeral role/task/selection/focus metadata
 *   - Latest-per-agent coalescing helper for ~30Hz cursor/presence updates
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

export type AgentPaletteSlot =
  | AgentColorSlot
  | 13
  | 14
  | 15

export const AGENT_COLOR_PALETTE = Object.freeze([
  '#E74C3C',
  '#3498DB',
  '#2ECC71',
  '#F39C12',
  '#9B59B6',
  '#1ABC9C',
  '#E91E63',
  '#00BCD4',
  '#8BC34A',
  '#FF9800',
  '#673AB7',
  '#795548',
  '#607D8B',
  '#CDDC39',
  '#FF5722',
] as const)

export interface AgentSelectionRange {
  readonly file: string
  readonly anchor: { readonly line: number; readonly column: number }
  readonly focus: { readonly line: number; readonly column: number }
}

export interface AgentFocusTarget {
  readonly kind: 'file' | 'symbol' | 'task' | 'panel'
  readonly id: string
  readonly label?: string
}

export interface AgentEphemeralPresence {
  readonly role?: string
  readonly currentTask?: string
  readonly selection?: AgentSelectionRange
  readonly focus?: AgentFocusTarget
  readonly updatedAt: string
}

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
  readonly presence?: AgentEphemeralPresence
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
  updatePresence(id: string, presence: AgentPresenceUpdate): void
  clearCursor(id: string): void
  heartbeat(id: string): void

  byState(state: AgentState): ReadonlyArray<Agent>
  withinFile(file: string): ReadonlyArray<Agent>

  subscribe(listener: (snapshot: ReadonlyArray<Agent>) => void): () => void
  subscribeAgent(id: string, listener: (agent: Agent) => void): () => void

  announceStateChange(id: string, prevState: AgentState): StateChangeAnnouncement | null

  reducedMotion(): boolean
}

export type AgentPresenceUpdate = Omit<Partial<AgentEphemeralPresence>, 'updatedAt'> & {
  readonly updatedAt?: string
}

export interface CoalescedPresenceUpdate extends AgentPresenceUpdate {
  readonly id: string
  readonly file?: string
  readonly cursor?: { readonly line: number; readonly column: number }
}

export interface PresenceUpdateCoalescer {
  readonly intervalMs: number
  enqueue(update: CoalescedPresenceUpdate): void
  flush(): void
  cancel(): void
}

export type AgentActivityEventType =
  | 'agent.started'
  | 'agent.completed'
  | 'agent.error'
  | 'conflict.detected'
  | 'conflict.resolved'
  | 'pr.merged'
  | 'edit.started'
  | 'file.locked'
  | 'file.unlocked'
  | 'commit.created'
  | 'pr.opened'

export type AgentActivitySeverity = 'critical' | 'high' | 'normal' | 'low'

export interface AgentActivityEvent {
  readonly id: string
  readonly type: AgentActivityEventType
  readonly agentId?: string
  readonly agentName?: string
  readonly file?: string
  readonly message?: string
  readonly severity?: AgentActivitySeverity
  readonly timestampMs: number
}

export interface AgentActivitySummary {
  readonly key: string
  readonly type: AgentActivityEventType
  readonly count: number
  readonly agentIds: ReadonlyArray<string>
  readonly files: ReadonlyArray<string>
  readonly severity: AgentActivitySeverity
  readonly startedAtMs: number
  readonly endedAtMs: number
  readonly message: string
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

/** FNV-1a hash mod 12, slots numbered 1..12 for existing --k-N tokens. */
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

export function colorForSlot(slot: AgentPaletteSlot): string {
  return AGENT_COLOR_PALETTE[slot - 1]!
}

export function assignAgentColorSlot(
  agentId: string,
  existing: ReadonlyMap<string, AgentPaletteSlot>,
): AgentPaletteSlot {
  const current = existing.get(agentId)
  if (current !== undefined) return current
  const used = new Set(existing.values())
  for (let slot = 1; slot <= AGENT_COLOR_PALETTE.length; slot += 1) {
    if (!used.has(slot as AgentPaletteSlot)) return slot as AgentPaletteSlot
  }
  return kSlot(agentId)
}

export function deriveSigil(name: string): AgentSigil {
  const cleaned = name.replace(/[^A-Za-z]/g, '').toUpperCase()
  const text = cleaned.length >= 2 ? cleaned.slice(0, 2) : cleaned.padEnd(2, '?')
  return Object.freeze({ text })
}

function nowIso(): string {
  return new Date().toISOString()
}

function freezePresence(update: AgentPresenceUpdate): AgentEphemeralPresence {
  const updatedAt = update.updatedAt ?? nowIso()
  return Object.freeze({
    role: update.role,
    currentTask: update.currentTask,
    selection: update.selection,
    focus: update.focus,
    updatedAt,
  })
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
        presence: prior?.presence,
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

    updatePresence(id: string, presence: AgentPresenceUpdate): void {
      const prior = map.get(id)
      if (prior === undefined) return
      const next: Agent = Object.freeze({
        ...prior,
        presence: freezePresence({
          role: presence.role ?? prior.presence?.role,
          currentTask: presence.currentTask ?? prior.presence?.currentTask,
          selection: presence.selection ?? prior.presence?.selection,
          focus: presence.focus ?? prior.presence?.focus,
          updatedAt: presence.updatedAt,
        }),
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

export function createPresenceUpdateCoalescer(
  apply: (update: CoalescedPresenceUpdate) => void,
  opts?: {
    readonly intervalMs?: number
    readonly setTimeout?: (fn: () => void, ms: number) => unknown
    readonly clearTimeout?: (handle: unknown) => void
  },
): PresenceUpdateCoalescer {
  const intervalMs = opts?.intervalMs ?? 33
  const setTimer = opts?.setTimeout ?? ((fn, ms) => globalThis.setTimeout(fn, ms))
  const clearTimer = opts?.clearTimeout ?? ((handle) => globalThis.clearTimeout(handle as never))
  const pending = new Map<string, CoalescedPresenceUpdate>()
  let timer: unknown | undefined

  function schedule(): void {
    if (timer !== undefined) return
    timer = setTimer(() => {
      timer = undefined
      coalescer.flush()
    }, intervalMs)
  }

  const coalescer: PresenceUpdateCoalescer = {
    intervalMs,

    enqueue(update: CoalescedPresenceUpdate): void {
      pending.set(update.id, Object.freeze({ ...pending.get(update.id), ...update }))
      schedule()
    },

    flush(): void {
      if (timer !== undefined) {
        clearTimer(timer)
        timer = undefined
      }
      const updates = [...pending.values()]
      pending.clear()
      for (const update of updates) apply(update)
    },

    cancel(): void {
      if (timer !== undefined) {
        clearTimer(timer)
        timer = undefined
      }
      pending.clear()
    },
  }

  return coalescer
}

const SEVERITY_RANK: Record<AgentActivitySeverity, number> = {
  low: 0,
  normal: 1,
  high: 2,
  critical: 3,
}

function maxSeverity(events: ReadonlyArray<AgentActivityEvent>): AgentActivitySeverity {
  let best: AgentActivitySeverity = 'low'
  for (const event of events) {
    const next = event.severity ?? defaultSeverity(event.type)
    if (SEVERITY_RANK[next] > SEVERITY_RANK[best]) best = next
  }
  return best
}

function defaultSeverity(type: AgentActivityEventType): AgentActivitySeverity {
  switch (type) {
    case 'agent.error':
    case 'conflict.detected':
      return 'critical'
    case 'conflict.resolved':
    case 'pr.merged':
      return 'high'
    case 'agent.started':
    case 'agent.completed':
      return 'normal'
    default:
      return 'low'
  }
}

export function summarizeActivityEvents(
  events: ReadonlyArray<AgentActivityEvent>,
  opts?: { readonly windowMs?: number },
): ReadonlyArray<AgentActivitySummary> {
  const windowMs = opts?.windowMs ?? 5000
  const buckets = new Map<string, AgentActivityEvent[]>()
  for (const event of events) {
    const windowStart = Math.floor(event.timestampMs / windowMs) * windowMs
    const key = `${windowStart}:${event.agentId ?? '*'}:${event.type}:${event.file ?? '*'}`
    const bucket = buckets.get(key)
    if (bucket === undefined) buckets.set(key, [event])
    else bucket.push(event)
  }

  const summaries: AgentActivitySummary[] = []
  for (const [key, bucket] of buckets) {
    const sorted = [...bucket].sort((a, b) => a.timestampMs - b.timestampMs)
    const first = sorted[0]
    const last = sorted[sorted.length - 1]
    if (first === undefined || last === undefined) continue
    const agentIds = [...new Set(sorted.flatMap((e) => (e.agentId === undefined ? [] : [e.agentId])))]
    const files = [...new Set(sorted.flatMap((e) => (e.file === undefined ? [] : [e.file])))]
    const count = sorted.length
    const actor = first.agentName ?? first.agentId ?? 'System'
    const target = files.length === 0 ? '' : ` in ${files.join(', ')}`
    const message = count === 1
      ? first.message ?? `${actor} ${first.type}${target}`
      : `${actor} ${first.type} x${count}${target}`
    summaries.push(Object.freeze({
      key,
      type: first.type,
      count,
      agentIds: Object.freeze(agentIds),
      files: Object.freeze(files),
      severity: maxSeverity(sorted),
      startedAtMs: first.timestampMs,
      endedAtMs: last.timestampMs,
      message,
    }))
  }

  return Object.freeze(summaries.sort((a, b) => a.startedAtMs - b.startedAtMs))
}

export function activityAnnouncement(
  event: AgentActivityEvent,
): StateChangeAnnouncement | null {
  const name = event.agentName ?? event.agentId ?? 'Agent'
  switch (event.type) {
    case 'agent.started':
      return Object.freeze({ text: `${name} started`, assertive: false })
    case 'agent.completed':
      return Object.freeze({ text: `${name} completed`, assertive: false })
    case 'agent.error':
      return Object.freeze({ text: `${name} reported an error`, assertive: true })
    case 'conflict.detected':
      return Object.freeze({
        text: `Conflict detected${event.file === undefined ? '' : ` in ${event.file}`}`,
        assertive: true,
      })
    case 'conflict.resolved':
      return Object.freeze({
        text: `Conflict resolved${event.file === undefined ? '' : ` in ${event.file}`}`,
        assertive: false,
      })
    case 'pr.merged':
      return Object.freeze({ text: event.message ?? 'Pull request merged', assertive: false })
    default:
      return null
  }
}
