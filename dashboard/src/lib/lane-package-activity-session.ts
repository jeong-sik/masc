import { effect, signal, type Signal } from '@preact/signals'
import { executionWorkspaceAuthority, type ExecutionWorkspaceAuthority } from '../store'
import { fetchLaneDeclaration, saveLaneDeclaration, LaneDeclarationError,
  type LaneDeclarationDocument, type LaneDeclarationReceipt } from '../api/lane-declarations'
import { readPackageActivity, writePackageActivity } from './lane-package-activity'

type File = { document: LaneDeclarationDocument; enabled: boolean }
type Draft = { base: File; enabled: boolean }
type State = { draft: Draft | null; current: File | null; phase: 'idle' | 'reading' | 'saving';
  uncertain: boolean; error: string | null; notice: string | null; receipt: LaneDeclarationReceipt | null }
const sessions = new Map<string, LanePackageActivitySession>()
const observations = new Map<string, Signal<number>>()
function observationFor(workspaceRoot: string) {
  let revision = observations.get(workspaceRoot)
  if (!revision) { revision = signal(0); observations.set(workspaceRoot, revision) }
  return revision
}
export function lanePackageActivityObservationRevision(authority: ExecutionWorkspaceAuthority | null) {
  return authority === null ? 0 : observationFor(authority.workspaceRoot).value
}
const message = (error: unknown) => error instanceof Error ? error.message : String(error)
const warnUnload = (event: BeforeUnloadEvent) => { event.preventDefault(); event.returnValue = '' }
let guarding = false
function syncGuard() {
  const dirty = [...sessions.values()].some(owner => owner.modified() || owner.state.peek().uncertain || owner.state.peek().phase === 'saving')
  if (typeof window === 'undefined' || dirty === guarding) return
  guarding = dirty
  if (dirty) window.addEventListener('beforeunload', warnUnload)
  else window.removeEventListener('beforeunload', warnUnload)
}

/** Owns only an activity intent. The raw declaration editor remains independent. */
export class LanePackageActivitySession {
  readonly state = signal<State>({ draft: null, current: null, phase: 'idle', uncertain: false, error: null, notice: null, receipt: null })
  private authority: ExecutionWorkspaceAuthority | null = null
  private version = 0
  private readController: AbortController | null = null
  // Save requests sent and not yet settled, whichever authority sent them.
  // Read uncertainty and an outstanding write are different facts: a read
  // that began while a write was in flight may predate it, so only a read
  // that began with no write outstanding can clear `uncertain`.
  private pendingWrites = 0
  constructor(readonly workspaceRoot: string, readonly sourcePath: string, readonly installationId: string) {}
  private update(change: Partial<State>) { this.state.value = { ...this.state.peek(), ...change }; syncGuard() }
  admits(authority: ExecutionWorkspaceAuthority) {
    return authority.workspaceRoot === this.workspaceRoot && executionWorkspaceAuthority.peek() === authority
  }
  ready(authority: ExecutionWorkspaceAuthority) {
    return this.admits(authority) && this.authority === authority && this.state.peek().phase === 'idle' && this.state.peek().current !== null
  }
  modified() { const draft = this.state.peek().draft; return draft !== null && draft.enabled !== draft.base.enabled }
  invalidate(authority: ExecutionWorkspaceAuthority | null) {
    if (this.authority === null || this.authority === authority) return
    const state = this.state.peek()
    this.authority = null; ++this.version; this.readController?.abort()
    this.update({ current: null, phase: 'idle', uncertain: state.uncertain || state.phase === 'saving',
      error: 'Workspace changed. Your activity draft is retained; read the current file before saving.' })
  }
  private owns(authority: ExecutionWorkspaceAuthority, version: number) { return this.admits(authority) && this.authority === authority && this.version === version }
  private async settle<T>(write: Promise<T>): Promise<T> {
    this.pendingWrites++
    try { return await write } finally { this.pendingWrites-- }
  }
  // A write may have changed the file; tell every mounted inventory of this
  // workspace to read again. No component callback owns this notification.
  private announceWrite() {
    const revision = observationFor(this.workspaceRoot)
    revision.value = revision.peek() + 1
  }
  private file(document: LaneDeclarationDocument): File {
    if (document.source_path !== this.sourcePath) throw new Error('The file does not match the selected declaration.')
    if (!document.validation.valid) throw new Error(`The declaration is invalid. Repair its TOML before changing activity. ${document.validation.messages.join(' ')}`)
    return { document, enabled: readPackageActivity(document.source_text, this.installationId) }
  }
  async read(authority: ExecutionWorkspaceAuthority) {
    if (!this.admits(authority) || this.state.peek().phase !== 'idle') return
    this.authority = authority; const version = ++this.version
    const writeOutstanding = this.pendingWrites > 0
    const controller = new AbortController(); this.readController = controller
    this.update({ phase: 'reading', current: null, error: null, notice: null })
    try {
      const current = this.file(await fetchLaneDeclaration(this.sourcePath, controller.signal))
      if (!this.owns(authority, version)) return
      const state = this.state.peek()
      this.update({ current, uncertain: writeOutstanding || this.pendingWrites > 0, draft: state.draft && (this.modified() || state.uncertain)
        ? state.draft : { base: current, enabled: current.enabled } })
    } catch (error) { if (this.owns(authority, version)) this.update({ error: message(error) }) }
    finally { if (this.owns(authority, version)) { this.readController = null; this.update({ phase: 'idle' }) } }
  }
  toggle(authority: ExecutionWorkspaceAuthority) {
    const { draft } = this.state.peek()
    if (this.ready(authority) && draft) this.update({ draft: { ...draft, enabled: !draft.enabled }, error: null, notice: null, receipt: null })
  }
  reapply(authority: ExecutionWorkspaceAuthority) {
    const { draft, current } = this.state.peek()
    if (this.ready(authority) && draft && current) this.update({ draft: { base: current, enabled: draft.enabled }, uncertain: this.pendingWrites > 0, error: null,
      notice: 'Only the activity value was reapplied to the current file. Review and save explicitly.' })
  }
  discard(authority: ExecutionWorkspaceAuthority) {
    const { current } = this.state.peek()
    if (this.admits(authority) && this.state.peek().phase === 'idle') this.update({ draft: current ? { base: current, enabled: current.enabled } : null,
      notice: 'Activity draft discarded. No file was changed.', error: null })
  }
  async save(authority: ExecutionWorkspaceAuthority): Promise<boolean> {
    const { draft, current, uncertain } = this.state.peek()
    if (!this.ready(authority) || !draft || !current || !this.modified() || uncertain) return false
    if (draft.base.document.source_revision !== current.document.source_revision) {
      this.update({ error: 'The file changed. Reapply only the activity value or discard the draft.' }); return false
    }
    let source: string
    try { source = writePackageActivity(draft.base.document.source_text, this.installationId, draft.enabled) }
    catch (error) { this.update({ error: message(error) }); return false }
    const version = ++this.version
    this.update({ phase: 'saving', error: null, notice: null })
    try {
      const receipt = await this.settle(saveLaneDeclaration({ mode: 'save', file_name: draft.base.document.file_name,
        source_text: source, expected_source_revision: draft.base.document.source_revision }))
      if (!this.owns(authority, version)) { this.announceWrite(); return false }
      const saved = this.file(receipt.document)
      if (saved.document.source_text !== source || saved.enabled !== draft.enabled) throw new Error('The save receipt does not match the activity draft.')
      const durable = receipt.write.durability === 'durable'
      this.update({ receipt, current: durable ? saved : null, draft: durable ? { base: saved, enabled: draft.enabled } : draft,
        uncertain: !durable || this.pendingWrites > 0, notice: durable ? 'Activity configuration saved. Worker application or cleanup is still pending reconciliation.'
          : 'A save response was received, but durability is unconfirmed. Read the current file before continuing.' })
      // Notify whichever inventory is mounted now, including a new mount that
      // appeared while this owner was saving.
      this.announceWrite()
      return true
    } catch (error) {
      // A write this owner no longer awaits may still have committed unless
      // the server definitely refused it.
      if (!this.owns(authority, version)) {
        if (!(error instanceof LaneDeclarationError && error.failure.code !== 'io_error')) this.announceWrite()
        return false
      }
      if (error instanceof LaneDeclarationError && error.failure.code === 'revision_conflict' && error.failure.current) {
        try { this.update({ current: this.file(error.failure.current), uncertain: this.pendingWrites > 0,
          error: 'The file changed; nothing was saved by this request. Your activity draft is retained.' }) }
        catch (cause) { this.update({ current: null, error: message(cause) }) }
      } else {
        const definiteRefusal = error instanceof LaneDeclarationError && error.failure.code !== 'io_error'
        this.update({ current: null, uncertain: !definiteRefusal,
          error: `${message(error)} ${definiteRefusal ? 'Your activity draft is retained.' : 'The save result is uncertain. Read the current file before continuing.'}` })
      }
      return false
    } finally { if (this.owns(authority, version)) this.update({ phase: 'idle' }) }
  }
}
export function lanePackageActivityFor(authority: ExecutionWorkspaceAuthority, sourcePath: string, installationId: string) {
  const key = JSON.stringify([authority.workspaceRoot, sourcePath, installationId])
  let owner = sessions.get(key)
  if (!owner) { owner = new LanePackageActivitySession(authority.workspaceRoot, sourcePath, installationId); sessions.set(key, owner) }
  return owner
}
effect(() => { const authority = executionWorkspaceAuthority.value; for (const owner of sessions.values()) owner.invalidate(authority) })
export function resetLanePackageActivitiesForTesting() { for (const owner of sessions.values()) owner.invalidate(null); sessions.clear(); observations.clear(); syncGuard() }
