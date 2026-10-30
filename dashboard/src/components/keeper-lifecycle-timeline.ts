// Keeper lifecycle event vocabulary: the verbs the supervisor emits, and the
// tone and label each one reads as.
//
// This file used to render a timeline of them. Nothing mounted that component
// (#33230), and what the rest of the dashboard imports is the vocabulary --
// tool-monitor-reactivity asks these two functions what an event is called
// and how it should look. The renderer is gone; the words stay.
//
// The lifecycle event stream is distinct from the FSM phase transitions
// (keeper-phase-strip.ts):
//   • Phase strip   — records FSM transitions (prev_phase → new_phase)
//   • Lifecycle     — records higher-level supervisor events
//     (Started, Reconciled, Restarted, Supervisor_cleaned, etc.)
//
// Both are useful together: lifecycle events say *why* a phase sequence
// happened (operator action, restart burst) while the transitions say *what*
// happened state-by-state.

// ── Lifecycle event categorisation ───────────────────────────────────────

type EventTone = 'ok' | 'warn' | 'bad' | 'info' | 'neutral'

// The custom-event vocabulary of `Keeper_lifecycle_events.t`
// (lib/keeper_registry/keeper_lifecycle_events.ml). Both maps below are typed
// `Record<LifecycleVerb, _>`, so adding a verb here fails the build until it
// has a tone *and* a label. They used to be two independent switches and drifted:
// `admission_denied` had a label but no tone, so a refused launch rendered in
// the muted `info` grey next to `purged`.
export const LIFECYCLE_VERBS = [
  'started',
  'reconciled',
  'restarted',
  'supervisor_cleaned',
  'purged',
  'admission_denied',
] as const

export type LifecycleVerb = (typeof LIFECYCLE_VERBS)[number]

const VERB_TONE: Record<LifecycleVerb, EventTone> = {
  started: 'ok',
  reconciled: 'ok',
  restarted: 'warn',
  supervisor_cleaned: 'neutral',
  purged: 'info',
  admission_denied: 'bad',
}

const VERB_LABEL: Record<LifecycleVerb, string> = {
  started: '기동됨',
  reconciled: '재조정됨',
  restarted: '재시작됨',
  supervisor_cleaned: '부재 Keeper 정리됨',
  purged: '완전 삭제됨',
  admission_denied: '기동 거부됨',
}

function verbOf(event: string): LifecycleVerb | null {
  const e = event.trim().toLowerCase()
  return (LIFECYCLE_VERBS as readonly string[]).includes(e) ? (e as LifecycleVerb) : null
}

/** Map well-known lifecycle event strings to a semantic tone. */
export function lifecycleEventTone(event: string): EventTone {
  const verb = verbOf(event)
  return verb === null ? 'info' : VERB_TONE[verb]
}

export function lifecycleEventLabel(event: string): string {
  const verb = verbOf(event)
  // Keeper_lifecycle_events.event_of_string maps anything outside the custom
  // vocabulary to None on purpose: phase-derived and operator strings reach
  // this timeline too, so the wire set here is open and the fallback stays.
  return verb === null ? event.replace(/_/g, ' ') : VERB_LABEL[verb]
}

