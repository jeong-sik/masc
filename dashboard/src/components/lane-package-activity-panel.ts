import { html } from 'htm/preact'
import { useEffect, useRef } from 'preact/hooks'
import type { ExecutionWorkspaceAuthority } from '../store'
import type { LaneAddonSnapshot } from '../api/lane-addons'
import type { LaneDeclarationSession } from '../lib/lane-declaration-sessions'
import { lanePackageActivityFor } from '../lib/lane-package-activity-session'
import { ActionButton } from './common/button'

export function LanePackageActivityPanel({ documents, authority, snapshot, onRefresh }: {
  documents: LaneDeclarationSession; authority: ExecutionWorkspaceAuthority; snapshot: LaneAddonSnapshot; onRefresh: () => void;
}) {
  const target = documents.state.value.activityTarget
  const owner = target === null ? null : lanePackageActivityFor(authority, target.sourcePath, target.installationId)
  const heading = useRef<HTMLHeadingElement>(null)
  useEffect(() => {
    if (owner) { heading.current?.focus(); void owner.read(authority) }
  }, [owner, authority])
  if (!target || !owner) return null
  const state = owner.state.value, busy = state.phase !== 'idle', ready = owner.ready(authority)
  const conflict = state.draft && state.current && state.draft.base.document.source_revision !== state.current.document.source_revision
  const observed = snapshot.configuration?.declarations.find(item => item.id === target.installationId && item.source_path === target.sourcePath)
  return html`<section class="min-w-0 rounded border border-[var(--border)] p-4 space-y-3" aria-label=${`Package activity ${target.installationId}`}>
    <header class="flex flex-wrap items-center justify-between gap-2">
      <h3 ref=${heading} tabIndex=${-1} class="font-semibold">Package on/off · ${target.installationId}</h3>
      <${ActionButton} onClick=${() => documents.closeActivity(authority)}>Close activity</${ActionButton}>
    </header>
    <p>Off keeps this declaration and retained observations, and asks the server to clean up its worker. On makes it eligible for reconciliation again. Existing TOML editor drafts are unchanged.</p>
    <p role="status">File activity (last read): ${state.current ? state.current.enabled ? 'On' : 'Off' : busy ? 'Reading…' : 'Unverified'}</p>
    <p role="status">${!observed ? 'Declaration application is not in the current observation.'
      : !observed.enabled ? observed.instance_id === null ? 'Observed configuration: Off · no current worker observed' : 'Observed configuration: Off requested · worker cleanup not yet confirmed'
        : observed.applied_revision === null ? 'Observed configuration: On · not yet applied'
          : observed.applied_revision !== observed.desired_revision ? 'Observed configuration: On · revision change pending' : 'Observed configuration: On · desired revision applied'}</p>
    ${observed && state.current && observed.enabled !== state.current.enabled && html`<p role="status">The file activity differs from the last inventory observation. Read current activity to refresh both; worker completion is tracked separately.</p>`}
    ${state.draft && html`<button type="button" class="rounded border border-[var(--border)] px-3 py-2 disabled:opacity-50" role="switch" aria-checked=${state.draft.enabled} aria-label=${`Activity draft for ${target.installationId}`}
      disabled=${!ready || state.uncertain} onClick=${() => owner.toggle(authority)}>
      Draft: ${state.draft.enabled ? 'On' : 'Off'} · ${state.draft.enabled ? 'Turn off' : 'Turn on'}
    </button>`}
    ${conflict && html`<p role="alert">The file changed. Reapply only the activity value to retain its newer binding, manifest and comments.</p>`}
    ${state.uncertain && html`<p role="alert">The previous save outcome is uncertain. A read shows the file now, but that save may still land later. Read the current file, then reapply only the activity value or discard the draft.</p>`}
    <div class="flex flex-wrap gap-2">
      <${ActionButton} variant="primary" disabled=${!ready || !owner.modified() || !!conflict || state.uncertain}
        onClick=${() => owner.save(authority)}>${state.phase === 'saving' ? 'Saving activity…' : 'Save activity'}</${ActionButton}>
      <${ActionButton} disabled=${busy} onClick=${async () => { await owner.read(authority); onRefresh() }}>Read current activity</${ActionButton}>
      ${(conflict || state.uncertain) && html`<${ActionButton} disabled=${!ready} onClick=${() => owner.reapply(authority)}>Reapply activity only</${ActionButton}>`}
      <${ActionButton} disabled=${busy || !state.draft} onClick=${() => owner.discard(authority)}>Discard activity draft</${ActionButton}>
      <${ActionButton} onClick=${() => documents.open(target.sourcePath, authority)}>Edit original TOML</${ActionButton}>
    </div>
    ${state.error && html`<p role="alert" class="break-words">${state.error}</p>`}
    ${state.notice && html`<p role="status">${state.notice}</p>`}
    ${state.receipt && html`<p role="status">Last save response: ${state.receipt.write.state} · durability ${state.receipt.write.durability}. ${state.receipt.write.detail ?? ''}</p>`}
    <details><summary>File and save revisions</summary><p class="break-all">${target.sourcePath}</p>
      <p class="break-all">Draft base: ${state.draft?.base.document.source_revision ?? 'Unverified'}</p>
      <p class="break-all">Last read: ${state.current?.document.source_revision ?? 'Unverified'}</p>
    </details>
  </section>`
}
