import { signal } from '@preact/signals'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import {
  fetchLaneDeclaration, saveLaneDeclaration, LaneDeclarationError,
  type LaneDeclarationDocument, type LaneDeclarationWrite,
} from '../api/lane-declarations'

export type LaneDeclarationEditorTarget = { key: string; sourcePath: string | null }
export type LaneDeclarationDraft = {
  fileName: string; sourcePath: string | null; text: string; document: LaneDeclarationDocument | null;
  current: LaneDeclarationDocument | null; phase: 'loading' | 'idle' | 'reading' | 'saving';
  error: string | null; notice: string | null; needsRead: boolean;
  retainedCreateDrafts: { text: string; sourceRevision: string }[];
}
const template = 'id = ""\nrun_id = ""\nmanifest_path = ""\n\n[binding]\nsources = []\n'
const message = (error: unknown) => error instanceof Error ? error.message : String(error)
const sessions = new Map<string, LaneDeclarationSession>()
let guardingUnload = false
const beforeUnload = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
function syncUnloadGuard() {
  const dirty = [...sessions.values()].some(session => Object.values(session.state.peek().drafts).some(draft =>
    draft.retainedCreateDrafts.length > 0 || draft.needsRead || (draft.document === null
      ? draft.fileName !== '' || draft.text !== template && draft.text !== ''
      : draft.text !== draft.document.source_text)))
  if (typeof window === 'undefined' || dirty === guardingUnload) return
  guardingUnload = dirty
  if (dirty) window.addEventListener('beforeunload', beforeUnload)
  else window.removeEventListener('beforeunload', beforeUnload)
}

/** In-memory owner, independent of Status/component mounts. Reads and writes
 * settle here; UI callbacks only refresh the visible installation inventory. */
export class LaneDeclarationSession {
  readonly state = signal<{ target: LaneDeclarationEditorTarget | null; newEditorKey: string;
    drafts: Record<string, LaneDeclarationDraft> }>({ target: null, newEditorKey: crypto.randomUUID(), drafts: {} })
  constructor(readonly workspaceRoot: string, readonly directory: string) {}

  admits(authority: ExecutionWorkspaceAuthority): boolean {
    return authority.workspaceRoot === this.workspaceRoot && executionWorkspaceAuthority.peek() === authority
  }
  update(key: string, change: (draft: LaneDeclarationDraft) => LaneDeclarationDraft) {
    const state = this.state.peek(), draft = state.drafts[key]
    if (draft === undefined) return
    this.state.value = { ...state, drafts: { ...state.drafts, [key]: change(draft) } }
    syncUnloadGuard()
  }
  private changedAuthority(key: string) {
    this.update(key, draft => ({ ...draft, phase: 'idle', current: null, needsRead: true,
      error: 'Workspace authority changed while the request was pending. Your draft is preserved. Read the current file before saving again.' }))
  }
  private pathFor(fileName: string): string | null {
    if (fileName === '' || fileName.includes('/') || fileName.includes('\\') || fileName.includes('\0')) return null
    return `${this.directory}${this.directory.endsWith('/') ? '' : '/'}${fileName}`
  }
  sourcePath(key: string): string | null {
    const draft = this.state.peek().drafts[key]
    return draft?.document?.source_path ?? draft?.sourcePath ?? this.pathFor(draft?.fileName ?? '')
  }
  open(sourcePath: string | null, authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority)) return
    const state = this.state.peek(), key = sourcePath ?? state.newEditorKey
    this.state.value = { ...state, target: { key, sourcePath }, drafts: state.drafts[key] ? state.drafts : {
      ...state.drafts, [key]: { fileName: '', sourcePath, text: sourcePath === null ? template : '', document: null,
        current: null, phase: 'idle', error: null, notice: null, needsRead: false, retainedCreateDrafts: [] },
    } }
    if (!state.drafts[key] && sourcePath !== null) void this.read(key, sourcePath, authority, true)
  }
  close() { this.state.value = { ...this.state.peek(), target: null } }

  async read(key: string, sourcePath: string, authority: ExecutionWorkspaceAuthority, initial = false) {
    const draft = this.state.peek().drafts[key]
    if (!this.admits(authority) || draft === undefined || draft.phase !== 'idle') return
    const controller = new AbortController()
    this.update(key, value => ({ ...value, phase: initial ? 'loading' : 'reading', error: null }))
    try {
      const document = await fetchLaneDeclaration(sourcePath, controller.signal)
      if (!this.admits(authority)) { this.changedAuthority(key); return }
      this.update(key, value => initial
        ? { ...value, fileName: document.file_name, text: document.source_text, document, phase: 'idle', needsRead: false }
        : { ...value, current: document, phase: 'idle', needsRead: false, notice: 'Current file read. Your draft is unchanged.' })
    } catch (error) {
      if (!this.admits(authority)) { this.changedAuthority(key); return }
      this.update(key, value => ({ ...value, phase: 'idle', error: message(error),
        needsRead: value.document === null && value.sourcePath === null
          && error instanceof LaneDeclarationError && error.failure.code === 'not_found' ? false : value.needsRead }))
    }
  }

  async save(key: string, authority: ExecutionWorkspaceAuthority): Promise<LaneDeclarationDocument | null> {
    const draft = this.state.peek().drafts[key]
    if (!this.admits(authority) || !draft || draft.phase !== 'idle' || draft.needsRead
      || draft.document === null && draft.sourcePath !== null) return null
    const expectedPath = draft.document?.source_path ?? this.pathFor(draft.fileName)
    if (expectedPath === null) return null
    const request: LaneDeclarationWrite = { file_name: draft.fileName, source_text: draft.text,
      ...(draft.document === null ? { mode: 'create' } : { mode: 'save', expected_source_revision: draft.document.source_revision }),
    }
    this.update(key, value => ({ ...value, phase: 'saving', error: null, notice: null }))
    try {
      const receipt = await saveLaneDeclaration(request)
      if (!this.admits(authority)) { this.changedAuthority(key); return null }
      if (receipt.document.source_path !== expectedPath) throw new Error('The receipt belongs to another configuration directory.')
      const state = this.state.peek(), value = state.drafts[key]
      if (!value) return null
      const savedKey = receipt.document.source_path
      const next: LaneDeclarationDraft = { ...value, sourcePath: savedKey, document: receipt.document, current: null, phase: 'idle', needsRead: false,
        notice: `${receipt.write.state === 'created' ? 'File created' : receipt.write.state === 'unchanged' ? 'File unchanged' : 'File saved'}. ${receipt.write.durability === 'unconfirmed' ? 'Durability is unconfirmed. ' : ''}Lane application is pending reconciliation. ${receipt.write.detail ?? ''}${value.text !== request.source_text ? ' Your newer draft edits are not saved.' : ''}`,
      }
      const remaining = { ...state.drafts }
      delete remaining[key]
      const destination = state.drafts[savedKey]
      // A discovered destination owns its newer draft/revision and in-flight
      // operation. Late create completion must not replace that owner.
      if (savedKey !== key && destination !== undefined) {
        remaining[savedKey] = { ...destination, retainedCreateDrafts: [...destination.retainedCreateDrafts, ...value.retainedCreateDrafts,
          ...(value.text !== request.source_text && value.text !== destination.text
            ? [{ text: value.text, sourceRevision: receipt.document.source_revision }] : [])] }
      } else remaining[savedKey] = next
      this.state.value = { drafts: remaining,
        target: state.target?.key === key ? { key: savedKey, sourcePath: savedKey } : state.target,
        newEditorKey: state.newEditorKey === key ? crypto.randomUUID() : state.newEditorKey }
      syncUnloadGuard()
      return receipt.document
    } catch (error) {
      if (!this.admits(authority)) { this.changedAuthority(key); return null }
      const current = error instanceof LaneDeclarationError ? error.failure.current : null
      this.update(key, value => ({ ...value, phase: 'idle',
        error: `${message(error)} Your draft is preserved.${error instanceof LaneDeclarationError ? '' : ' The file may already have changed; read the current file before saving again.'}`,
        current: current?.source_path === expectedPath ? current : value.current,
      }))
      return null
    }
  }
  useCurrent(key: string, replaceDraft: boolean, authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority)) return
    const draft = this.state.peek().drafts[key]
    if (!draft || draft.phase !== 'idle' || draft.needsRead || !draft.current) return
    const current = draft.current
    this.update(key, value => ({ ...value, document: current, fileName: current.file_name,
      text: replaceDraft ? current.source_text : value.text, current: null, error: null, needsRead: false,
      notice: replaceDraft ? 'Draft replaced with the displayed current file.' : 'Current file revision selected for the next save. Your draft is unchanged.' }))
  }
}

export function laneDeclarationSessionFor(authority: ExecutionWorkspaceAuthority, directory: string): LaneDeclarationSession {
  const key = JSON.stringify([authority.workspaceRoot, directory])
  let session = sessions.get(key)
  if (!session) { session = new LaneDeclarationSession(authority.workspaceRoot, directory); sessions.set(key, session) }
  return session
}

/** Test isolation for this process-memory owner; no persistent storage exists. */
export function resetLaneDeclarationSessionsForTesting() {
  sessions.clear()
  syncUnloadGuard()
}
