// How an FSM phase-transition event reads. The timeline that drew them was
// mounted nowhere (#33230); observatory/event-track and
// tool-monitor-reactivity want the label, so that is what is left.

export function eventLabel(event: unknown): string {
  if (typeof event === 'string') return event
  if (event && typeof event === 'object' && 'type' in event) {
    const type = (event as Record<string, unknown>).type
    if (type != null) return String(type)
  }
  return '?'
}

