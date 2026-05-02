import { signal } from '@preact/signals'

export type InterjectActionKind = 'send' | 'approve' | 'pause' | 'drain'

export interface InterjectDispatchRequest {
  readonly kind: InterjectActionKind
  readonly keeper_id: string
  readonly message?: string
  readonly timestamp_ms: number
}

export interface InterjectActionState {
  readonly kind: InterjectActionKind
  readonly label: string
  readonly primary: boolean
  readonly requires_message: boolean
  readonly enabled: boolean
  readonly disabled_reason: string | null
}

export interface InterjectSnapshot {
  readonly active_keeper_id: string | null
  readonly message: string
  readonly busy_action: InterjectActionKind | null
  readonly error: string | null
  readonly last_dispatch: InterjectDispatchRequest | null
}

export type InterjectActionAvailability = {
  readonly enabled: boolean
  readonly disabled_reason?: string
}

export type InterjectActionPolicy = Partial<Record<InterjectActionKind, InterjectActionAvailability>>

export interface InterjectStore {
  readonly snapshot: () => InterjectSnapshot
  readonly actions: () => ReadonlyArray<InterjectActionState>
  readonly setActiveKeeper: (keeperId: string | null | undefined) => void
  readonly setMessage: (message: string) => void
  readonly submit: (kind: InterjectActionKind) => Promise<boolean>
  readonly reset: () => void
  readonly subscribe: (listener: () => void) => () => void
}

const ACTIONS: ReadonlyArray<{
  readonly kind: InterjectActionKind
  readonly label: string
  readonly primary: boolean
  readonly requires_message: boolean
}> = [
  { kind: 'send', label: 'Send', primary: true, requires_message: true },
  { kind: 'approve', label: 'Approve', primary: false, requires_message: false },
  { kind: 'pause', label: 'Pause', primary: false, requires_message: false },
  { kind: 'drain', label: 'Drain', primary: false, requires_message: false },
]

const DEFAULT_ACTION_POLICY: Required<InterjectActionPolicy> = {
  send: { enabled: true },
  approve: {
    enabled: false,
    disabled_reason: 'No active approval token is attached to the IDE interject rail.',
  },
  pause: {
    enabled: false,
    disabled_reason: 'Keeper-scoped pause is not advertised by the operator action surface.',
  },
  drain: {
    enabled: false,
    disabled_reason: 'Keeper-scoped drain is not advertised by the operator action surface.',
  },
}

export function createInterjectStore({
  initialActiveKeeper,
  actionPolicy = {},
  dispatch,
  now = () => Date.now(),
}: {
  readonly initialActiveKeeper?: string | null
  readonly actionPolicy?: InterjectActionPolicy
  readonly dispatch: (request: InterjectDispatchRequest) => Promise<void>
  readonly now?: () => number
}): InterjectStore {
  const snapshotSignal = signal<InterjectSnapshot>({
    active_keeper_id: normalizeKeeper(initialActiveKeeper),
    message: '',
    busy_action: null,
    error: null,
    last_dispatch: null,
  })
  const policy = { ...DEFAULT_ACTION_POLICY, ...actionPolicy }

  const setSnapshot = (next: InterjectSnapshot): void => {
    snapshotSignal.value = next
  }

  const setActiveKeeper = (keeperId: string | null | undefined): void => {
    const nextKeeper = normalizeKeeper(keeperId)
    const current = snapshotSignal.value
    if (current.active_keeper_id === nextKeeper) return
    setSnapshot({ ...current, active_keeper_id: nextKeeper, error: null })
  }

  const setMessage = (message: string): void => {
    const current = snapshotSignal.value
    if (current.message === message) return
    setSnapshot({ ...current, message, error: null })
  }

  const actions = (): ReadonlyArray<InterjectActionState> =>
    ACTIONS.map(action => deriveActionState(action, snapshotSignal.value, policy))

  const submit = async (kind: InterjectActionKind): Promise<boolean> => {
    const action = actions().find(item => item.kind === kind)
    const current = snapshotSignal.value
    if (!action) {
      setSnapshot({ ...current, error: `Unknown INTERJECT action: ${kind}` })
      return false
    }
    if (!action.enabled) {
      setSnapshot({ ...current, error: action.disabled_reason ?? `${action.label} is unavailable` })
      return false
    }

    const keeperId = current.active_keeper_id
    if (!keeperId) {
      setSnapshot({ ...current, error: 'Choose an active keeper before using INTERJECT.' })
      return false
    }

    const message = current.message.trim()
    const request: InterjectDispatchRequest = {
      kind,
      keeper_id: keeperId,
      message: message === '' ? undefined : message,
      timestamp_ms: now(),
    }

    setSnapshot({ ...current, busy_action: kind, error: null })
    try {
      await dispatch(request)
      const after = snapshotSignal.value
      setSnapshot({
        ...after,
        message: kind === 'send' ? '' : after.message,
        busy_action: null,
        error: null,
        last_dispatch: request,
      })
      return true
    } catch (err) {
      const after = snapshotSignal.value
      setSnapshot({
        ...after,
        busy_action: null,
        error: err instanceof Error ? err.message : String(err),
      })
      return false
    }
  }

  const reset = (): void => {
    const current = snapshotSignal.value
    setSnapshot({ ...current, message: '', busy_action: null, error: null, last_dispatch: null })
  }

  const subscribe = (listener: () => void): (() => void) => {
    let sawInitialSnapshot = false
    return snapshotSignal.subscribe(() => {
      if (!sawInitialSnapshot) {
        sawInitialSnapshot = true
        return
      }
      listener()
    })
  }

  return {
    snapshot: () => snapshotSignal.value,
    actions,
    setActiveKeeper,
    setMessage,
    submit,
    reset,
    subscribe,
  }
}

function deriveActionState(
  action: (typeof ACTIONS)[number],
  snapshot: InterjectSnapshot,
  policy: Required<InterjectActionPolicy>,
): InterjectActionState {
  const availability = policy[action.kind]
  const message = snapshot.message.trim()
  let disabledReason: string | null = null

  if (snapshot.busy_action !== null) {
    disabledReason = `${snapshot.busy_action} is still running.`
  } else if (!snapshot.active_keeper_id) {
    disabledReason = 'Choose an active keeper before using INTERJECT.'
  } else if (action.requires_message && message === '') {
    disabledReason = 'Type a message before sending.'
  } else if (!availability.enabled) {
    disabledReason = availability.disabled_reason ?? `${action.label} is not available.`
  }

  return {
    kind: action.kind,
    label: action.label,
    primary: action.primary,
    requires_message: action.requires_message,
    enabled: disabledReason === null,
    disabled_reason: disabledReason,
  }
}

function normalizeKeeper(value: string | null | undefined): string | null {
  const normalized = value?.trim()
  return normalized ? normalized : null
}
