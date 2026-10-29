import { html } from 'htm/preact'
import type { LaneAddonInstance, LaneAddonRow } from '../api/lane-addons'
import { parseBrowserConnections, type BrowserConnection, type BrowserInteraction } from '../api/browser-lane-connections'
import { formatLaneTime } from './lane-addons-timeline'

const browsers: Record<BrowserConnection['browser'], string> = { firefox: 'Firefox', zen: 'Zen', ego_lite: 'Ego Lite' }
const transports: Record<BrowserConnection['transport'], string> = {
  ego_task_space: 'Ego TaskSpace', webdriver_bidi: 'WebDriver BiDi', web_extension: 'Web extension',
}
const outcomes: Record<BrowserConnection['lastActivities'][number]['outcome'], string> = {
  returned: 'Returned', refused: 'Not performed', partial: 'Partly performed', unknown: 'Outcome unknown',
}
function interaction(work: BrowserInteraction) {
  return html`<span>${work.actor ?? 'Caller not recorded'} · ${work.action} · ${work.tabId === null ? 'Space scope' : `Tab ${work.tabId}`}
    <span class="break-all"> · Request ${work.requestId}</span></span>`
}

/** A connection publication is an observation, never browser control authority
 * or a statement that its native window is visible. Keep the worker row actor
 * separate from each host-recorded caller; one aggregate can contain many. */
export function BrowserLaneConnections({ row, instances }: {
  row: LaneAddonRow; instances: readonly LaneAddonInstance[];
}) {
  const owners = instances.filter(instance => instance.addon_id === 'browser'
    && row.lane_id === `${instance.instance_id}/browser/connections`)
  const owner = owners.length === 1 ? owners[0] : undefined
  if (owner === undefined) return null
  const observation = parseBrowserConnections(row.fields)
  return html`<section class="space-y-2" aria-label=${`Browser connections for ${row.id}`}>
    <h4 class="font-semibold">Browser callers and Spaces</h4>
    <p>Observed ${formatLaneTime(row.observed_at)}${owner.runtime_presence === 'retained' ? ' · Retained worker observation' : ''}.
      Refresh observations to read newer activity.</p>
    ${observation.kind === 'unreadable' ? html`<p role="status">Browser connection observation unreadable. Original fields remain available.</p>`
      : html`<div class="space-y-3">
        <p>Worker state at observation: ${observation.value.state}</p>
        ${observation.value.unavailable?.map((item, index) => html`<p key=${index} aria-label="Ego connection unavailable">
          Ego connection unavailable at ${formatLaneTime(item.observedAt)}: the name ${item.space} matched a user-owned Space.
          This observation is rechecked on worker restart.</p>`)}
        ${observation.value.clients.length === 0 && html`<p>No live connections recorded in this observation.</p>`}
        ${observation.value.clients.map(client => html`<article key=${client.clientId} class="border border-[var(--border)] rounded p-2 space-y-1"
          aria-label=${`Browser client ${client.clientId}`}>
          <h5 class="font-semibold">${browsers[client.browser]} · ${transports[client.transport]}</h5>
          <p class="break-all">Client ${client.clientId} · browser ${client.version} · engine ${client.engineVersion}</p>
          ${client.space !== null && html`<p>Space ${client.space.id} · ${client.space.name}</p>`}
          ${client.transport === 'ego_task_space' && (client.spaceObservation === null
            ? html`<p>No SDK control observation recorded. Window visibility and login are unverified.</p>`
            : html`<p>Last SDK control observation: ${client.spaceObservation.ownership} ·
                ${formatLaneTime(client.spaceObservation.observedAt)} · Space ${client.spaceObservation.spaceId} · ${client.spaceObservation.spaceName}.
                This does not verify current control, window visibility or login.</p>`)}
          <h6>Requests pending at observation</h6>
          ${client.interactions.length === 0 ? html`<p>No pending requests recorded.</p>` : html`<ul>
            ${client.interactions.map(work => html`<li key=${work.requestId}>${work.phase === 'queued' ? 'Queued' : 'Running'} · ${interaction(work)}</li>`)}
          </ul>`}
          <h6>Last recorded result per caller</h6>
          ${client.lastActivities.length === 0 ? html`<p>No previous result recorded.</p>` : html`<ul>
            ${client.lastActivities.map(({ work, outcome }) => html`<li key=${work.requestId}>${outcomes[outcome]} · ${interaction(work)}</li>`)}
          </ul>`}
        </article>`)}
        <h5 class="font-semibold">Server-owned browser sessions</h5>
        <p>These session observations do not identify a current caller or verify login.</p>
        ${(['automation', 'stagehand'] as const).map(backend => {
          const session = observation.value.owned_backends[backend]
          const name = backend === 'automation' ? 'Automation' : 'Stagehand'
          return html`<article key=${backend} class="border border-[var(--border)] rounded p-2 space-y-1"
            aria-label=${`${name} browser session`}>
            <h6 class="font-semibold">${name}</h6>
            <p>Availability at observation: ${session.activity}</p>
            <p>Executor registered: ${session.registered ? 'yes' : 'no'}</p>
            <p>Browser session at observation: ${session.session}</p>
          </article>`
        })}
      </div>`}
  </section>`
}
