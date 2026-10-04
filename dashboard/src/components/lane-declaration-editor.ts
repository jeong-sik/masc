import { html } from 'htm/preact'
import type { ExecutionWorkspaceAuthority } from '../store'
import type { LaneDeclarationDraft, LaneDeclarationSession } from '../lib/lane-declaration-sessions'
import { ActionButton } from './common/button'
import { TextArea, TextInput } from './common/input'

/** The session owner survives component unmounts; this component projects it. */
export function LaneDeclarationEditor({ session, authority, onSaved }: {
  session: LaneDeclarationSession; authority: ExecutionWorkspaceAuthority; onSaved: () => void;
}) {
  const state = session.state.value
  const target = state.target
  if (target === null) return null
  const draft = state.drafts[target.key]
  if (draft === undefined) return null
  const busy = draft.phase !== 'idle'
  const existing = draft.document !== null
  const loaded = target.sourcePath === null || existing
  const sourcePath = draft.document?.source_path ?? target.sourcePath
  const readPath = session.sourcePath(target.key)
  const modified = draft.document === null || draft.text !== draft.document.source_text
  const key = target.key
  const update = (key: string, change: (value: LaneDeclarationDraft) => LaneDeclarationDraft) => session.update(key, change)
  const onClose = () => session.close()
  async function save() {
    if (await session.save(key, authority)) onSaved()
  }
  const useCurrent = (replaceDraft: boolean) => session.useCurrent(key, replaceDraft, authority)
  return html`<section class="space-y-3 rounded border border-[var(--border)] p-4" aria-label="Lane TOML editor">
    <header class="flex flex-wrap items-center justify-between gap-2">
      <h3 class="font-semibold">${sourcePath === null ? 'New TOML' : 'Edit TOML'}</h3>
      <${ActionButton} variant="ghost" onClick=${onClose}>Close editor</${ActionButton}>
    </header>
    <p>Save a declaration file in the configured Lane directory. Installation and observation status are shown separately in the Lane tables.</p>
    ${sourcePath !== null && html`<p class="break-all">File: <code>${sourcePath}</code></p>`}
    <label class="block">File name
      <${TextInput} value=${draft.fileName} disabled=${existing || target.sourcePath !== null || busy} placeholder="my-lane.toml"
        onInput=${(event: Event) => update(key, value => ({ ...value, fileName: (event.target as HTMLInputElement).value }))} />
    </label>
    ${draft.document && html`<div class="space-y-1 break-all">
      <p>File source revision: <code>${draft.document.source_revision}</code></p>
      <p>Parsed declaration revision: <code>${draft.document.desired_revision ?? 'Unavailable'}</code></p>
      <p>Dashboard and Keeper saves check this source revision. Direct filesystem writes do not share the editor lock. Parsed and applied declaration revisions describe Lane configuration.</p>
      ${!draft.document.validation.valid && html`<div role="alert">The current file is invalid. Its original text is available for correction.
        ${draft.document.validation.messages.map((text, index) => html`<p key=${index}>${text}</p>`)}
      </div>`}
    </div>`}
    ${draft.phase === 'loading' && html`<p role="status">Reading original TOML…</p>`}
    <label class="block">TOML source
      <${TextArea} value=${draft.text} rows=${14} class="block w-full font-mono" disabled=${!loaded}
        onInput=${(event: Event) => update(key, value => ({ ...value, text: (event.target as HTMLTextAreaElement).value }))} />
    </label>
    <div class="flex flex-wrap gap-2">
      <${ActionButton} variant="primary" disabled=${busy || !loaded || !modified || draft.needsRead || draft.current !== null || draft.fileName === ''} ariaBusy=${draft.phase === 'saving'} onClick=${save}>
        ${draft.phase === 'saving' ? 'Saving TOML…' : 'Save TOML'}
      </${ActionButton}>
      ${readPath !== null && html`<${ActionButton} disabled=${busy} onClick=${() => session.read(key, readPath, authority, !loaded)}>
        ${draft.phase === 'reading' ? 'Reading current file…' : 'Read current file'}
      </${ActionButton}>`}
    </div>
    ${draft.error !== null && html`<p role="alert">${draft.error}</p>`}
    ${draft.notice !== null && html`<p role="status">${draft.notice}</p>`}
    ${draft.retainedCreateDrafts.map((retained, index) => html`<section key=${index} class="space-y-2" aria-label=${`Retained create draft ${index + 1} comparison`}>
      <p>These unsaved edits were made while the create response was pending. Your separately opened draft is unchanged. Copy any edits you need into the current draft before saving.</p>
      <p>Created file source revision: <code>${retained.sourceRevision}</code></p>
      <label class="block">Retained create draft ${index + 1}
        <${TextArea} value=${retained.text} readOnly rows=${6} class="block w-full font-mono" />
      </label>
      <${ActionButton} onClick=${() => update(key, value => ({ ...value,
        retainedCreateDrafts: value.retainedCreateDrafts.filter((_, retainedIndex) => retainedIndex !== index),
      }))}>Discard retained create draft ${index + 1}</${ActionButton}>
    </section>`)}
    ${draft.current !== null && html`<section class="space-y-2" aria-label="Current file comparison">
      <p>Current file source revision: <code>${draft.current.source_revision}</code></p>
      <pre class="overflow-auto whitespace-pre-wrap break-all" aria-label="Current file source">${draft.current.source_text}</pre>
      <div class="flex flex-wrap gap-2">
        <${ActionButton} disabled=${busy} onClick=${() => useCurrent(false)}>Use current file revision</${ActionButton}>
        <${ActionButton} disabled=${busy} onClick=${() => useCurrent(true)}>Replace draft with current file</${ActionButton}>
      </div>
    </section>`}
  </section>`
}
