import { html } from 'htm/preact'
import type { LaneAddonApplication, LaneAddonInstance, LaneAddonSnapshot } from '../api/lane-addons'

/** Describes host facts; this projection never starts, stops or authorizes a worker. */
export function laneAddonApplicationText(application: LaneAddonApplication): string {
  switch (application.kind) {
    case 'starting': return 'Waiting for worker startup'
    case 'cleaning': return 'Worker cleanup pending'
    case 'applied': return `Worker running · ${application.instance_id}`
    case 'inactive': return 'Off · worker cleanup confirmed'
    case 'failed': return `Application failed · ${application.messages.join('; ')}`
    case 'unknown': return `Application unknown · ${application.messages.join('; ')}`
  }
}

function workerRecord(worker: LaneAddonInstance) {
  return html`<article key=${worker.instance_id} class="border-l border-[var(--border)] pl-3 my-2"
    aria-label=${`Worker ${worker.instance_id} · incarnation ${worker.incarnation}`}>
    <p class="break-all">${worker.instance_id} · ${worker.runtime_presence} · ${worker.phase.kind}${worker.phase.message ? ` · ${worker.phase.message}` : ''}</p>
    <p class="break-all">Installation: ${worker.configuration!.id}</p>
    <p class="break-all">Incarnation: ${worker.incarnation}</p>
    <p class="break-all">TOML: ${worker.configuration!.source_path}</p>
    <p class="break-all">Installed revision: ${worker.configuration!.revision}</p>
    <p>Completed observation sequence: ${worker.observation_seq} · retained rows: ${worker.rows_count}</p>
    ${worker.observation_seq === 0 && html`<p>No completed observation received for this worker.</p>`}
  </article>`
}

export function LaneAddonConnection({ snapshot, installationId, sourcePath, expectedSourceRevision }: {
  snapshot: LaneAddonSnapshot; installationId: string; sourcePath: string; expectedSourceRevision?: string;
}) {
  const configuration = snapshot.configuration
  const declarations = configuration?.declarations.filter(item => item.id === installationId || item.source_path === sourcePath) ?? []
  const candidate = declarations.length === 1 ? declarations[0]! : null
  const declaration = candidate?.id === installationId && candidate.source_path === sourcePath ? candidate : null
  // Installation IDs survive revision changes and renames. Never join by title,
  // package ID or run ID: those can belong to unrelated installations.
  const workers = snapshot.instances.filter(item => item.configuration?.id === installationId)
  const otherPathOwners = snapshot.instances.filter(item => item.configuration !== null
    && item.configuration.id !== installationId && item.configuration.source_path === sourcePath)
  return html`<div class="space-y-2" aria-label=${`Connection lifecycle ${installationId}`}>
    <p role="status">${!configuration?.complete ? 'Application unknown · configuration inventory is incomplete'
      : !declaration ? 'Application unknown · no unique declaration in this observation'
        : expectedSourceRevision !== undefined && declaration.source_revision !== expectedSourceRevision
          ? 'Different TOML revision observed · this file’s application is not confirmed'
        : laneAddonApplicationText(declaration.application)}</p>
    <p>Startup and cleanup describe the worker. Completed observations and action results remain separate evidence.</p>
    <details aria-label="Workers with this installation ID"><summary>Workers with this installation ID · ${workers.length}</summary>
      ${workers.length === 0 && html`<p>No worker records received for this installation.</p>`}
      ${workers.map(workerRecord)}
    </details>
    ${otherPathOwners.length > 0 && html`<details aria-label="Other installation owners at this TOML path">
      <summary>Other installation IDs at this TOML path · ${otherPathOwners.length}</summary>
      <p>These are separate installation owners. Their retained results and cleanup status do not describe the selected installation.</p>
      ${otherPathOwners.map(workerRecord)}
    </details>`}
  </div>`
}
