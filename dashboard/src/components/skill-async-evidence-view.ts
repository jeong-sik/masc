import { html } from 'htm/preact'
import type { SkillActivationEvidence } from '../api/dashboard-skills'
import type { DashboardSkillAsyncAction } from '../api/dashboard-tools-prompts'
import { skillAsyncOccurrenceIdentity } from '../api/dashboard-tools-prompts'
import { projectSkillAsyncEvidence } from '../lib/skill-async-evidence'

function occurrenceLabel(action: DashboardSkillAsyncAction): string {
  const occurrence = action.occurrence
  if (occurrence.kind === 'native_started') {
    const identity = occurrence.identity
    const label = identity.kind === 'call_id'
      ? `call ${identity.call_id}`
      : `step ${identity.conversation_id}:${identity.step_index}`
    return `Native started · official turn ${occurrence.official_turn} · ${label}`
  }
  const result = occurrence.result
  const outcome = result.kind === 'handler_returned'
    ? 'SDK returned'
    : `SDK errored · ${result.error_class ?? 'unclassified'} · recoverable ${result.recoverable}`
  return `${outcome} · call ${occurrence.invocation.tool_use_id} · SDK turn ${occurrence.invocation.turn} · ${result.bytes} B · ${result.sha256}`
}

export function SkillAsyncEvidenceView({ evidence }: { evidence: SkillActivationEvidence }) {
  const view = projectSkillAsyncEvidence(evidence)
  if (view.resultDeliveries.length === 0 && view.actionLinkCount === 0) return null
  return html`
    <div class="mt-2 space-y-1" data-testid="skill-async-evidence">
      <div class="ss-muted">Async results · ${view.resultDeliveries.length} handoffs · ${view.actions.length} physical actions · ${view.actionLinkCount} causal links</div>
      ${view.resultDeliveries.map((delivery, index) => html`
        <details class="text-3xs" key=${index}>
          <summary class="cursor-pointer ss-muted">
            ${delivery.presentation === 'inline_result' ? 'Inline result delivered' : 'Manifest reference delivered'}
            · ${delivery.boundary.kind === 'model_response' ? 'provider' : 'official client'}
            · received ${delivery.physical_turn_ref} · ${delivery.runtime_id}
          </summary>
          <div class="ss-muted mono break-all">
            original ${delivery.original_turn_ref} · run ${delivery.composition_run_id} · parent ${delivery.logical_parent_tool_use_id}
            · request ${delivery.request_id} · ${delivery.observed_at}
          </div>
          <div class="ss-muted mono break-all">${delivery.receipt.content_bytes} B · ${delivery.receipt.content_sha256}</div>
        </details>
      `)}
      ${view.actions.map(group => {
        const action = group.first
        return html`
          <details class="text-3xs" key=${skillAsyncOccurrenceIdentity(action)}>
            <summary class=${action.occurrence.kind === 'sdk_result' && action.occurrence.result.kind === 'handler_errored' ? 'cursor-pointer text-[var(--color-status-bad)]' : 'cursor-pointer ss-muted'}>
              ${action.tool_name} · ${action.occurrence.kind === 'native_started' ? 'Native started' : action.occurrence.result.kind === 'handler_returned' ? 'SDK returned' : 'SDK errored'}
              · received ${action.physical_turn_ref} · ${action.runtime_id}
            </summary>
            <div class="ss-muted mono break-all">${occurrenceLabel(action)}</div>
            ${[group.first, ...group.additionalLinks].map(link => html`
              <div class="ss-muted mono break-all" key=${link.delivery_sha256}>causal handoff ${link.delivery_sha256} · ${link.observed_at}</div>
            `)}
          </details>
        `
      })}
    </div>
  `
}
