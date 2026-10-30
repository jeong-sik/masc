import { html } from 'htm/preact'
import { useMemo, useState } from 'preact/hooks'
import { route, replaceRoute } from '../router'
import { executionWorkspaceAuthority, refreshExecution } from '../store'
import { parseLaneTarget, type LaneNavigationTarget } from '../lib/lane-navigation'
import { ActionButton } from './common/button'

export function useLaneNavigation(kinds: readonly LaneNavigationTarget['kind'][]) {
  const raw = route.value.params.lane_target
  const parsed = useMemo(() => parseLaneTarget(raw), [raw])
  const authority = executionWorkspaceAuthority.value
  const target = parsed.kind === 'target' ? parsed.target : null
  const error = parsed.kind === 'invalid' ? parsed.message
    : target && !kinds.includes(target.kind) ? 'This Lane target belongs to another settings surface.'
      : target && authority && target.workspace !== authority.workspaceRoot ? 'This Lane link belongs to another workspace. Its target was not opened here.' : null
  return { raw, target, error, pending: target !== null && authority === null, authority }
}
export function clearLaneNavigation() {
  const current = route.peek()
  if (current.params.lane_target === undefined) return
  const params = { ...current.params }; delete params.lane_target
  replaceRoute(current.tab, params)
}
export function LaneNavigationNotice({ message, pending = false, onRetry }: { message: string; pending?: boolean; onRetry?: () => void }) {
  const [reading, setReading] = useState(false), [error, setError] = useState<string | null>(null)
  return html`<section aria-label="Lane navigation" class="rounded border border-[var(--border)] p-4 space-y-3">
    <p role=${pending ? 'status' : 'alert'}>${message}</p>
    ${pending && html`<${ActionButton} disabled=${reading} onClick=${async () => {
      setReading(true); setError(null)
      try { await refreshExecution({ force: true }) } catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)) }
      finally { setReading(false) }
    }}>Verify workspace</${ActionButton}>`}
    ${error && html`<p role="alert">${error}</p>`}
    ${onRetry && html`<${ActionButton} onClick=${onRetry}>Read target again</${ActionButton}>`}
    <${ActionButton} onClick=${clearLaneNavigation}>Open this workspace without the target</${ActionButton}>
  </section>`
}
