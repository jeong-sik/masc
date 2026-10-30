import { html } from 'htm/preact'
import type { LaneAddonInstance } from '../api/lane-addons'
import type { LaneAddonHostRequestCycle } from '../api/lane-addon-host-requests'

function waitText(wait: LaneAddonHostRequestCycle['waiting'][number]['reason']): string {
  switch (wait.reason) {
    case 'lane_unconfigured': return 'No model lane configured'
    case 'lane_off': return 'Model lane is off'
    case 'no_admitted_slots': return 'No admitted model slot'
    case 'attempt_in_progress': return 'An attempt is running'
    case 'awaiting_operator': return 'Waiting for the operator’s answer'
    case 'lane_registry_unavailable': return `Lane registry unavailable: ${wait.detail}`
    case 'provider_unavailable': return `Provider unavailable: ${wait.detail}`
    case 'provider_auth_refused': return `Provider refused authentication: ${wait.detail}`
    case 'provider_configuration_refused': return `Provider refused configuration: ${wait.detail}`
    case 'source_unavailable': return `Source unavailable: ${wait.detail}`
  }
}
function issueText(issue: NonNullable<LaneAddonHostRequestCycle['issue']>): string {
  switch (issue.kind) {
    case 'listing_failed': return `Request listing failed: ${issue.detail}`
    case 'listing_refused': return `Request listing refused: ${issue.detail}`
    case 'relisted_delivered_request': return `Request ${issue.request_id} was listed again after delivery`
    case 'result_delivery_failed': return `Delivering request ${issue.request_id} failed: ${issue.detail}`
    case 'exact_record_failed': return `Recording request ${issue.request_id} failed: ${issue.detail}`
    case 'ask_record_failed': return `Recording question ${issue.request_id} failed: ${issue.detail}`
    case 'no_exact_runner': return 'This host has no exact-output runner'
  }
}

/** Read only: a last-cycle observation belongs to this original incarnation.
 * It is neither a live provider probe, an attempt history nor a success receipt. */
export function LaneAddonHostRequests({ instance }: { instance: LaneAddonInstance }) {
  const observation = instance.host_requests
  if (observation === undefined) return null
  const summary = observation.kind === 'unreadable' ? 'observation unreadable'
    : `${observation.cycle.waiting.length} waiting${observation.cycle.issue === null ? '' : ' · issue reported'}`
  return html`<details aria-label=${`Host requests for ${instance.instance_id} · incarnation ${instance.incarnation}`}>
    <summary>Last host cycle · ${summary}</summary>
    <p class="break-all">Worker: ${instance.instance_id} · incarnation ${instance.incarnation}</p>
    ${observation.kind === 'unreadable'
      ? html`<p role="status">Host request observation unreadable: ${observation.detail}</p>`
      : html`<div>
        <p>Cycle passes: ${observation.cycle.cycles}</p>
        ${observation.cycle.waiting.length === 0
          ? html`<p>No waiting requests were reported in this cycle.</p>`
          : html`<ul>${observation.cycle.waiting.map((request, index) => html`<li key=${index}>
            <span class="break-all">${request.request_id}</span>: ${waitText(request.reason)}
          </li>`)}</ul>`}
        ${observation.cycle.issue !== null && html`<p role="status">${issueText(observation.cycle.issue)}</p>`}
      </div>`}
    <p>This is the last received cycle for this worker. Results, delivery receipts and cleanup are separate evidence.</p>
  </details>`
}
