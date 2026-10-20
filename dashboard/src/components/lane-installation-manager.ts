import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import type { LaneAddonSnapshot } from '../api/lane-addons'
import { ActionButton } from './common/button'
import { LaneAddonConnection } from './lane-addon-connection'
import { installationReadings, installationStatusLabels, matchesInstallation,
  type InstallationFilter, type LaneDeclaration } from '../lib/lane-installation-status'

const control = 'rounded border border-[var(--border)] bg-transparent px-3 py-2 disabled:opacity-50'
const filters: readonly { value: InstallationFilter; label: string }[] = [
  { value: 'all', label: 'All installations' }, { value: 'attention', label: 'Needs attention' },
  { value: 'pending', label: 'Pending changes' }, { value: 'off', label: 'Configured off' },
  { value: 'available', label: 'Worker available' },
]

export function LaneInstallationManager({ snapshot, editable, readState, onEdit, onActivity, onObserve }: {
  snapshot: LaneAddonSnapshot; editable: boolean;
  readState: 'settled' | 'pending' | 'failed';
  onEdit: (path: string) => void; onActivity: (declaration: LaneDeclaration) => void;
  onObserve: (instance: string) => void;
}) {
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<InstallationFilter>('all')
  const readings = installationReadings(snapshot)
  const visible = readings.filter(reading => matchesInstallation(reading, query, filter))
  return html`<div class="space-y-3" aria-label="Installed package manager">
    <p>Find an installation, edit its settings, then check its applied revision and worker observation. Saving TOML and applying it are separate steps.</p>
    <div class="flex flex-wrap gap-2" aria-label="Installation summary">
      ${filters.map(item => html`<${ActionButton} key=${item.value} variant="ghost" size="sm"
        pressed=${filter === item.value} onClick=${() => setFilter(item.value)}>
        ${item.label}: ${readings.filter(reading => matchesInstallation(reading, '', item.value)).length}
      </${ActionButton}>`)}
    </div>
    <label class="block">Search installations<input type="search" class=${`${control} block w-full`} value=${query}
      placeholder="Installation, package, run or file" onInput=${(event: Event) => setQuery((event.target as HTMLInputElement).value)} /></label>
    <p role="status">Showing ${visible.length} of ${readings.length} readable installations. Worker state is the last inventory reading, not a live health check.</p>
    ${readState !== 'settled' && html`<p role="status">${readState === 'pending'
      ? 'Refreshing inventory; previous installation states remain visible.'
      : 'Inventory refresh failed; current installation states are unverified.'} Check observation is unavailable until Refresh succeeds.</p>`}
    <div class="overflow-x-auto"><table class="w-full text-left" aria-label="TOML declarations"><thead><tr>
      <th>Installation / package</th><th>Requested activity</th><th>Application / worker status</th><th>Settings and observation</th>
    </tr></thead><tbody>${visible.map(({ declaration, worker, status, issues, canObserve }) => html`<tr key=${declaration.source_path} aria-label=${`Installation ${declaration.id}`}>
      <td class="align-top p-2"><strong>${declaration.id}</strong>
        ${worker && html`<p>${worker.title} · ${worker.revision}</p><p>Run: ${worker.run_id}</p>`}
        <details><summary>File and revisions</summary><p class="break-all">${declaration.source_path}</p>
          <p class="break-all">File revision: <span>${declaration.source_revision ?? 'Unverified'}</span></p>
          <p class="break-all">Desired revision: <span>${declaration.desired_revision}</span></p>
          <p class="break-all">Applied revision: <span>${declaration.applied_revision ?? 'None'}</span></p>
          <p class="break-all">Instance: <span>${declaration.instance_id ?? 'No instance'}</span></p>
          ${worker && html`<p class="break-all">Incarnation: ${worker.incarnation}</p>`}
        </details></td>
      <td class="align-top p-2">${declaration.enabled ? 'Requested: On' : 'Requested: Off'}</td>
      <td class="align-top p-2"><p role="status">${installationStatusLabels[status]}</p>
        <${LaneAddonConnection} snapshot=${snapshot} installationId=${declaration.id} sourcePath=${declaration.source_path} />
        ${issues.map(issue => html`<p class="whitespace-pre-wrap break-words">${issue}</p>`)}
        ${worker && html`<p>Observation sequence: ${worker.observation_seq} · retained rows: ${worker.rows_count}</p>
          ${(worker.phase.message || worker.error) && html`<p role="status" class="break-words">${worker.phase.message ?? worker.error}</p>`}
          <p>${worker.action_schema === null ? 'Observation only' : 'Package actions advertised'} · outputs: ${Object.keys(worker.package.outputs).join(', ') || 'None'}</p>`}
        ${declaration.instance_id !== null && worker === null && html`<p>The inventory does not confirm a unique worker for this file and applied revision.</p>`}
      </td>
      <td class="align-top p-2"><div class="flex flex-wrap gap-2">
        <button type="button" class=${control} disabled=${!editable} onClick=${() => onEdit(declaration.source_path)} aria-label=${`Edit TOML ${declaration.source_path}`}>Edit TOML</button>
        <button type="button" class=${control} disabled=${!editable} onClick=${() => onActivity(declaration)} aria-label=${`Configure activity for ${declaration.id}`}>On / off</button>
        <button type="button" class=${control} disabled=${!canObserve || readState !== 'settled'} aria-label=${`Observe installation ${declaration.id}`}
          onClick=${() => { if (canObserve && worker && readState === 'settled') onObserve(worker.instance_id) }}>Check observation</button>
      </div></td>
    </tr>`)}</tbody></table></div>
    ${readings.length === 0 ? html`<p>No readable TOML declarations.</p>`
      : visible.length === 0 && html`<p>No installations match. Clear the search or choose All installations.</p>`}
  </div>`
}
