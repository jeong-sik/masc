import { html } from 'htm/preact'
import { useState } from 'preact/hooks'
import { TextInput } from './common/input'
import { ActionButton } from './common/button'
import { LaneBindingField } from './lane-binding-form'
import type { LaneAddonSnapshot } from '../api/lane-addons'
import type { ExecutionWorkspaceAuthority } from '../store'
import type { LaneDeclarationSession } from '../lib/lane-declaration-sessions'
import { lanePackageInstallationFor } from '../lib/lane-package-installation-session'
import type { BindingInput } from '../lib/lane-binding-form'
import { addonCategoryGroups, categoryGroup, categoryLabel, groupAddonCategories, type AddonCategoryFilter } from '../lib/lane-addon-category'
import { LaneAddonCategoryFilter } from './lane-addon-category-filter'

export function LanePackageInstaller({ authority, documents, snapshot, onSelectionChange }: {
  authority: ExecutionWorkspaceAuthority; documents: LaneDeclarationSession; snapshot: LaneAddonSnapshot; onSelectionChange?: () => void;
}) {
  const owner = lanePackageInstallationFor(authority, documents.directory)
  const state = owner.state.value
  const [category, setCategory] = useState<AddonCategoryFilter>('all')
  const packages = state.catalog?.entries.filter(entry => entry.kind === 'package') ?? []
  const groups = groupAddonCategories(packages, entry => categoryGroup(entry.ui_category), category)
  const { folderInput: directory, manifestInput: manifest } = state
  if (!state.visible) return html`<${ActionButton} onClick=${() => { onSelectionChange?.(); owner.open(authority) }}>Install package</${ActionButton}>`
  const busy = state.phase !== 'idle'
  const selectedKey = state.selected
  const selected = selectedKey === null ? undefined : state.drafts.get(selectedKey)
  return html`<section aria-label="Package installer" class="min-w-0 space-y-4 rounded border border-[var(--border)] p-4">
    <header class="flex flex-wrap items-center justify-between gap-3"><h3 class="font-semibold">Install a local package</h3>
      <${ActionButton} onClick=${() => owner.close()}>Close installer</${ActionButton}></header>
    <p>Choose a package, fill its input fields, then prepare a local TOML draft. Only Save TOML writes the declaration.</p>
    ${state.error && html`<p role="alert" class="whitespace-pre-wrap break-words">${state.error}</p>`}
    ${busy && html`<p role="status">${state.phase === 'catalog' ? 'Reading local packages…' : 'Reading package execution…'}</p>`}
    <div class="flex flex-wrap items-end gap-2"><label class="min-w-0 flex-1">Workspace folder
      <${TextInput} class="w-full" value=${directory} placeholder=${state.folder ?? 'Workspace root'} onInput=${(event: Event) => owner.editPath('folderInput', (event.target as HTMLInputElement).value, authority)} /></label>
      <${ActionButton} disabled=${busy} onClick=${() => owner.browse(directory === '' ? null : directory, authority)}>Open folder</${ActionButton}>
      <${ActionButton} disabled=${busy} onClick=${() => owner.browse(state.folder, authority)}>Refresh packages</${ActionButton}>
      ${state.catalog && state.catalog.parent !== null && html`<${ActionButton} disabled=${busy} onClick=${() => owner.browse(state.catalog!.parent, authority)}>Parent folder</${ActionButton}>`}
    </div>
    ${state.catalog && html`<div class="space-y-2"><p class="break-all">Folder: ${state.catalog.directory}</p>
      <p class="text-sm">This folder and immediate child folders. Browse folders to find deeper packages.</p>
      ${state.catalog.entries.length === 0 && html`<p>No local packages or child folders here.</p>`}
      <ul class="space-y-2">${state.catalog.entries.filter(entry => entry.kind !== 'package').map(entry => html`<li key=${JSON.stringify([entry.kind, entry.path])} class="rounded border border-[var(--border)] p-3 break-words">
        ${entry.kind === 'folder' ? html`<${ActionButton} disabled=${busy} onClick=${() => owner.browse(entry.path, authority)}>Open ${entry.path}</${ActionButton}>`
          : html`<p role="status" class="break-all">${entry.path}: ${entry.message}</p>`}
      </li>`)}</ul>
      <${LaneAddonCategoryFilter} label="패키지 역할 필터" value=${category} onChange=${setCategory}
        groups=${addonCategoryGroups.filter(group => group !== 'unavailable')} />
      ${packages.length > 0 && groups.length === 0 && html`<p>No packages match this role. Choose 전체 역할 to see every package.</p>`}
      ${groups.map(group => html`<section key=${group.category} class="space-y-2" aria-label=${`Packages · ${categoryLabel(group.category)}`}>
        <h4 class="font-semibold">${categoryLabel(group.category)}</h4>
        <ul class="space-y-2">${group.items.map(entry => html`<li key=${entry.manifest_path} class="rounded border border-[var(--border)] p-3 break-words">
          <div class="space-y-2"><h5 class="font-semibold">${entry.title} · ${entry.revision}</h5>
            ${entry.description && html`<p class="whitespace-pre-wrap">${entry.description}</p>`}<p class="break-all text-sm">${entry.manifest_path}</p>
            <${ActionButton} disabled=${busy} onClick=${() => { onSelectionChange?.(); void owner.preview(entry.manifest_path, authority) }}>Choose ${entry.title}</${ActionButton}>
            <${ActionButton} disabled=${busy} onClick=${() => owner.browse(entry.manifest_path.slice(0, entry.manifest_path.lastIndexOf('/')) || '/', authority)}>Open package folder</${ActionButton}>
          </div>
        </li>`)}</ul>
      </section>`)}</div>`}
    <details><summary>Enter a manifest path directly</summary><label class="block">Package manifest path
      <${TextInput} class="w-full" value=${manifest} onInput=${(event: Event) => owner.editPath('manifestInput', (event.target as HTMLInputElement).value, authority)} /></label>
      <${ActionButton} disabled=${busy || !manifest.trim()} onClick=${() => { onSelectionChange?.(); void owner.preview(manifest, authority) }}>Read package preview</${ActionButton}></details>
    ${(state.drafts.size > 1 || state.drafts.size > 0 && selectedKey === null) && html`<label class="block">Retained package inputs<select aria-label="Retained package inputs" class="block w-full rounded border p-2 bg-[var(--bg)]"
      value=${selectedKey ?? ''} onChange=${(event: Event) => { onSelectionChange?.(); owner.select((event.target as HTMLSelectElement).value, authority) }}>
      ${selectedKey === null && html`<option value="">Choose retained package inputs</option>`}
      ${[...state.drafts].map(([key, draft], index) => html`<option value=${key}>${draft.preview.package.title} · ${draft.id || 'unnamed'} · input set ${index + 1}</option>`)}
    </select></label>`}
    ${selected && selectedKey !== null && html`<fieldset disabled=${busy} class="min-w-0 space-y-4"><legend class="font-semibold">Configure ${selected.preview.package.title} · ${selected.preview.package.revision}</legend>
      <p class="break-all">${selected.preview.manifest_path}</p>
      <p>현재 패키지 역할: ${categoryLabel(categoryGroup(selected.preview.package.ui_category))}</p>
      ${selected.preview.execution.kind === 'host_process' ? html`<p>Runs as a host process.</p>`
        : html`<p class="break-all">Image: ${selected.preview.execution.image_name}</p>
          <p class="break-words">${(selected.preview.execution.image.state === 'available' ? `Available: ${selected.preview.execution.image.digest}` : `Image unverified: ${selected.preview.execution.image.detail}`)}</p>`}
      ${selected.previewAuthority !== authority && html`<p role="status">A fresh package preview is required. Inputs are retained; recheck the package before preparing a draft.</p>`}
      <${ActionButton} onClick=${() => owner.preview(selected.preview.manifest_path, authority)}>Recheck package</${ActionButton}>
      <label class="block">Installation ID<${TextInput} class="block w-full" value=${selected.id} onInput=${(event: Event) => owner.update(selectedKey, { id: (event.target as HTMLInputElement).value }, authority)} /></label>
      <label class="block">Run ID<${TextInput} class="block w-full" value=${selected.runId} onInput=${(event: Event) => owner.update(selectedKey, { runId: (event.target as HTMLInputElement).value }, authority)} /></label>
      <${LaneBindingField} schema=${selected.schema} input=${selected.input} name="binding" path=${[]} required=${true}
        runId=${selected.runId} snapshot=${snapshot} onChange=${(input: BindingInput) => owner.update(selectedKey, { input }, authority)} />
      <${ActionButton} variant="primary" onClick=${() => { onSelectionChange?.(); owner.prepare(selectedKey, documents, authority) }}>Prepare TOML draft</${ActionButton}>
    </fieldset>`}
  </section>`
}
