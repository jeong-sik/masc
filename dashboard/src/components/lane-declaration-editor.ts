import { html } from 'htm/preact'
import { useCallback, useEffect, useRef, useState } from 'preact/hooks'
import {
  fetchLaneDeclaration, saveLaneDeclaration, LaneDeclarationError,
  type LaneDeclarationDocument, type LaneDeclarationWrite,
} from '../api/lane-declarations'
import { ActionButton } from './common/button'
import { TextArea, TextInput } from './common/input'

export type LaneDeclarationEditorTarget = { key: string; sourcePath: string | null }
type Draft = {
  fileName: string; text: string; document: LaneDeclarationDocument | null;
  current: LaneDeclarationDocument | null; phase: 'loading' | 'idle' | 'reading' | 'saving';
  error: string | null; notice: string | null;
}
const template = 'id = ""\nrun_id = ""\nmanifest_path = ""\n\n[binding]\nsources = []\n'
const message = (error: unknown) => error instanceof Error ? error.message : String(error)

/** File sessions stay mounted across status refreshes, closing, and switching files. */
export function LaneDeclarationEditor({ target, onClose, onSaved }: {
  target: LaneDeclarationEditorTarget | null; onClose: () => void; onSaved: (key: string, document: LaneDeclarationDocument) => void;
}) {
  const [drafts, setDrafts] = useState<Record<string, Draft>>({})
  const started = useRef(new Set<string>())
  const reads = useRef(new Map<string, AbortController>())
  const saves = useRef(new Set<string>())
  const mounted = useRef(true)
  const update = useCallback((key: string, change: (draft: Draft) => Draft) => {
    if (mounted.current) setDrafts(all => all[key] === undefined ? all : { ...all, [key]: change(all[key]) })
  }, [])
  useEffect(() => {
    mounted.current = true
    const controllers = reads.current
    return () => { mounted.current = false; for (const controller of controllers.values()) controller.abort() }
  }, [])
  const read = useCallback(async (key: string, sourcePath: string, initial: boolean) => {
    const controller = new AbortController()
    reads.current.set(key, controller)
    update(key, draft => ({ ...draft, phase: initial ? 'loading' : 'reading', error: null }))
    try {
      const document = await fetchLaneDeclaration(sourcePath, controller.signal)
      if (controller.signal.aborted) return
      update(key, draft => initial
        ? { ...draft, fileName: document.file_name, text: document.source_text, document, phase: 'idle' }
        : { ...draft, current: document, phase: 'idle', notice: 'Current file read. Your draft is unchanged.' })
    } catch (error) {
      if (!controller.signal.aborted) update(key, draft => ({ ...draft, phase: 'idle', error: message(error) }))
    } finally { reads.current.delete(key) }
  }, [update])
  useEffect(() => {
    if (target === null || started.current.has(target.key)) return
    started.current.add(target.key)
    setDrafts(all => ({ ...all, [target.key]: {
      fileName: '', text: target.sourcePath === null ? template : '', document: null, current: null,
      phase: target.sourcePath === null ? 'idle' : 'loading', error: null, notice: null,
    } }))
    if (target.sourcePath !== null) void read(target.key, target.sourcePath, true)
  }, [target, read])
  const dirty = Object.values(drafts).some(draft => draft.document === null
    ? draft.fileName !== '' || draft.text !== template && draft.text !== ''
    : draft.text !== draft.document.source_text)
  useEffect(() => {
    if (!dirty) return undefined
    const beforeUnload = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
    window.addEventListener('beforeunload', beforeUnload)
    return () => window.removeEventListener('beforeunload', beforeUnload)
  }, [dirty])

  if (target === null) return null
  const draft = drafts[target.key]
  if (draft === undefined) return html`<p role="status">Opening TOML editor…</p>`
  const busy = draft.phase !== 'idle'
  const existing = draft.document !== null
  const loaded = target.sourcePath === null || existing
  const sourcePath = draft.document?.source_path ?? target.sourcePath
  const modified = draft.document === null || draft.text !== draft.document.source_text
  const key = target.key

  async function save() {
    if (!draft || !loaded || saves.current.has(key) || draft.phase !== 'idle') return
    const request: LaneDeclarationWrite = { file_name: draft.fileName, source_text: draft.text,
      ...(draft.document === null ? { mode: 'create' } : { mode: 'save', expected_source_revision: draft.document.source_revision }),
    }
    saves.current.add(key)
    update(key, value => ({ ...value, phase: 'saving', error: null, notice: null }))
    try {
      const receipt = await saveLaneDeclaration(request)
      if (!mounted.current) return
      const savedKey = receipt.document.source_path
      started.current.add(savedKey)
      setDrafts(all => {
        const value = all[key]
        if (value === undefined) return all
        const next: Draft = { ...value, document: receipt.document, current: null, phase: 'idle',
          notice: `${receipt.write.state === 'created' ? 'File created' : receipt.write.state === 'unchanged' ? 'File unchanged' : 'File saved'}. ${receipt.write.durability === 'unconfirmed' ? 'Durability is unconfirmed. ' : ''}Lane application is pending reconciliation. ${receipt.write.detail ?? ''}${value.text !== request.source_text ? ' Your newer draft edits are not saved.' : ''}`,
        }
        const remaining = { ...all }
        delete remaining[key]
        return { ...remaining, [savedKey]: next }
      })
      onSaved(key, receipt.document)
    } catch (error) {
      update(key, value => ({ ...value, phase: 'idle',
        error: `${message(error)} Your draft is preserved.${error instanceof LaneDeclarationError ? '' : ' The file may already have changed; read the current file before saving again.'}`,
        current: error instanceof LaneDeclarationError ? error.failure.current : value.current,
      }))
    } finally { saves.current.delete(key) }
  }
  function useCurrent(replaceDraft: boolean) {
    const current = draft?.current
    if (current === undefined || current === null) return
    update(key, value => ({ ...value, document: current, fileName: current.file_name,
      text: replaceDraft ? current.source_text : value.text, current: null, error: null,
      notice: replaceDraft ? 'Draft replaced with the displayed current file.' : 'Current file revision selected for the next save. Your draft is unchanged.',
    }))
  }
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
      <p>The file source revision protects concurrent edits. Parsed and applied declaration revisions describe Lane configuration.</p>
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
      <${ActionButton} variant="primary" disabled=${busy || !loaded || !modified || draft.fileName === ''} ariaBusy=${draft.phase === 'saving'} onClick=${save}>
        ${draft.phase === 'saving' ? 'Saving TOML…' : 'Save TOML'}
      </${ActionButton}>
      ${sourcePath !== null && html`<${ActionButton} disabled=${busy} onClick=${() => read(key, sourcePath, !loaded)}>
        ${draft.phase === 'reading' ? 'Reading current file…' : 'Read current file'}
      </${ActionButton}>`}
    </div>
    ${draft.error !== null && html`<p role="alert">${draft.error}</p>`}
    ${draft.notice !== null && html`<p role="status">${draft.notice}</p>`}
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
