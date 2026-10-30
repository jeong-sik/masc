import * as Y from 'yjs'
import { sendArtifactDraftCommand, type ArtifactDraftView } from '../api/artifact-drafts'
import { streamArtifactDraft, sendArtifactPresence, sameDraftTarget, type ArtifactDraftPeer, type ArtifactDraftLiveFrame, type ArtifactDraftPosition } from '../api/artifact-draft-live'
import { retainArtifactDraft, discardArtifactDraftRecovery, type ArtifactDraftRecovery } from './artifact-draft-recovery'
import type { ArtifactWorkspace } from '../api/published-artifacts'
import { restoreSharedDocument, sharedSource, selectSharedSource, resolveSharedSelection, type SourceSelection } from './artifact-shared-document'

export function draftBytes(text: string): Uint8Array { return Uint8Array.from(atob(text), char => char.charCodeAt(0)) }
export function draftBase64(bytes: Uint8Array): string { return btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join('')) }
const remote = Symbol('authenticated draft state')
function samePosition(a: ArtifactDraftPosition | null, b: ArtifactDraftPosition | null): boolean {
  if (!a || !b) return a === b
  return a.anchor.length === b.anchor.length && a.head.length === b.head.length
    && a.anchor.every((value, index) => value === b.anchor[index])
    && a.head.every((value, index) => value === b.head[index])
}
export type ArtifactSourceAnchor = { position: ArtifactDraftPosition; quote: string; mode: 'source' | 'html_text'; state: string }
export type ArtifactLiveState = {
  connection: 'connecting' | 'connected' | 'disconnected'; saving: boolean; pending: boolean;
  message: string; recoveryPersisted: boolean; peers: readonly ArtifactDraftPeer[]; sessionId: string | null; view: ArtifactDraftView;
}

// One local document survives a transport failure. Only explicit reconnection
// retries CRDT merge data; guarded Keeper replacements are never retried here.
export class ArtifactLiveSession {
  readonly doc: Y.Doc
  private state: ArtifactLiveState
  private pending: Uint8Array | null = null
  private mergeFlight: { batch: Uint8Array; controller: AbortController } | null = null
  private positionFlight: AbortController | null = null
  private position: ArtifactDraftPosition | null = null
  private announcedPosition: { sessionId: string; position: ArtifactDraftPosition | null } | null = null
  private lastSelection: Omit<ArtifactSourceAnchor, 'state'> | null = null
  private positionDirty = false
  private connection: AbortController | null = null
  private disposed = false
  private lifecycle = 0
  private recoveryId = crypto.randomUUID()
  private recoveryCopy: ArtifactDraftRecovery | null = null
  private persisted = true
  constructor(view: ArtifactDraftView, readonly workspace: ArtifactWorkspace, private changed: (state: ArtifactLiveState) => void, private isCurrent: () => boolean = () => true) {
    this.doc = restoreSharedDocument(draftBytes(view.draft.state))
    this.state = { connection: 'connecting', saving: false, pending: false, recoveryPersisted: true, message: '', peers: [], sessionId: null, view }
    this.doc.on('update', this.update)
  }
  get snapshot(): ArtifactLiveState { return this.state }
  get content(): string { return sharedSource(this.doc) }
  get current(): boolean { return !this.disposed && this.isCurrent() }
  captureCurrent(): () => boolean {
    const lifecycle = this.lifecycle
    return () => this.current && this.lifecycle === lifecycle
  }
  captureSource(): ArtifactSourceAnchor {
    if (!this.current || !this.lastSelection) throw new Error('원문에서 문장을 먼저 선택해 주세요.')
    const range = resolveSharedSelection(this.doc, { anchor: [...this.lastSelection.position.anchor], head: [...this.lastSelection.position.head] })
    if (!range || this.content.slice(Math.min(range.anchor, range.head), Math.max(range.anchor, range.head)) !== this.lastSelection.quote) {
      throw new Error('선택한 원문이 바뀌었습니다. 문장을 다시 선택해 주세요.')
    }
    return { ...this.lastSelection, position: structuredClone(this.lastSelection.position), state: draftBase64(Y.encodeStateAsUpdate(this.doc)) }
  }
  acceptServerView(view: ArtifactDraftView): boolean {
    if (!this.current || !sameDraftTarget(view.draft.target, this.state.view.draft.target)) return false
    this.receive(view); return true
  }
  private emit(patch: Partial<ArtifactLiveState> = {}): void {
    if (this.disposed) return
    this.state = { ...this.state, ...patch, pending: this.pending !== null || this.mergeFlight !== null, saving: this.mergeFlight !== null, recoveryPersisted: this.persisted }
    this.changed(this.state)
  }
  private update = (update: Uint8Array, origin: unknown) => {
    if (origin === remote || this.disposed) return
    this.pending = this.pending ? Y.mergeUpdates([this.pending, update]) : update
    this.retain(); this.emit(); void this.flush()
  }
  private retain(): void {
    this.recoveryCopy = retainArtifactDraft(this.recoveryId, this.workspace, this.state.view.draft.target, draftBase64(Y.encodeStateAsUpdate(this.doc)))
    this.persisted = this.recoveryCopy.persisted
  }
  recover(state: Uint8Array): void { Y.applyUpdate(this.doc, state) }
  private receive(view: ArtifactDraftView): void {
    // Merge in both directions without replacing unacknowledged local edits.
    Y.applyUpdate(this.doc, draftBytes(view.draft.state), remote)
    if (view.draft.sequence >= this.state.view.draft.sequence) this.emit({ view })
  }
  private frame = (frame: ArtifactDraftLiveFrame): void => {
    if (!this.isCurrent()) { this.disconnect(); this.emit({ message: '작업 공간 또는 인증이 바뀌었습니다. 원고를 보관하고 편집을 다시 열어 주세요.' }); return }
    if (frame.document) this.receive(frame.document)
    this.emit({ connection: 'connected', message: '', sessionId: frame.session_id, peers: frame.peers })
    void this.flush()
  }
  async connect(): Promise<void> {
    this.disconnect()
    if (this.disposed || !this.isCurrent()) return
    const connection = new AbortController()
    this.connection = connection
    this.emit({ connection: 'connecting', message: '' })
    this.positionDirty = true
    try {
      await streamArtifactDraft(this.state.view.draft.target, this.workspace,
        frame => { if (this.connection === connection && !this.disposed) this.frame(frame) }, connection.signal)
    } catch (error) {
      if (this.connection !== connection || this.disposed) return
      this.emit({ connection: 'disconnected', peers: [], sessionId: null,
        message: error instanceof Error ? error.message : '공동 편집 연결이 끊겼습니다.' })
    }
  }
  private disconnect(): void {
    const sessionId = this.state.sessionId
    // Leave is sent before aborting so surviving observers immediately remove
    // this cursor. A broken transport also triggers server-side cleanup.
    if (sessionId) void sendArtifactPresence(this.state.view.draft.target, sessionId, this.workspace, { action: 'leave' }).catch(() => {})
    this.connection?.abort(); this.connection = null
    this.announcedPosition = null
    this.emit({ peers: [], sessionId: null, connection: 'disconnected' })
  }
  private async flush(): Promise<void> {
    if (this.disposed || this.mergeFlight || this.state.connection !== 'connected' || !this.isCurrent()) return
    if (!this.pending) { void this.flushPosition(); return }
    const batch = this.pending
    const currentAttempt = this.captureCurrent()
    const flight = { batch, controller: new AbortController() }
    this.pending = null; this.mergeFlight = flight; this.emit()
    try {
      const view = await sendArtifactDraftCommand({ action: 'merge', target: this.state.view.draft.target, updates: [draftBase64(batch)] }, this.workspace, flight.controller.signal)
      if (this.mergeFlight === flight && currentAttempt()) this.receive(view)
      else if (this.mergeFlight === flight && !this.disposed) {
        // A pre-hide reply must not update a restored session. Preserve the
        // CRDT update for the existing explicit reconnect/reconciliation path.
        this.pending = this.pending ? Y.mergeUpdates([batch, this.pending]) : batch
        this.retain()
        this.emit({ message: '이전 저장 요청을 확인하려면 다시 연결해 주세요.' })
      }
    } catch (error) {
      if (this.mergeFlight === flight) {
        this.pending = this.pending ? Y.mergeUpdates([batch, this.pending]) : batch
        if (currentAttempt()) this.disconnect()
        this.emit({ message: error instanceof Error ? error.message : '공유 원고 저장 결과를 확인하지 못했습니다.' })
      }
    } finally {
      if (this.mergeFlight === flight) {
        this.mergeFlight = null
        if (!this.disposed && !this.pending && this.recoveryCopy) {
          discardArtifactDraftRecovery(this.recoveryCopy); this.recoveryCopy = null
        }
        this.emit()
      }
    }
    if (currentAttempt() && this.state.connection === 'connected') void this.flush()
  }
  select(selection: SourceSelection | null, mode: ArtifactSourceAnchor['mode'] = 'source'): void {
    if (this.disposed) return
    this.position = selection ? selectSharedSource(this.doc, selection) : null
    if (selection && this.position) this.lastSelection = { position: this.position, mode,
      quote: this.content.slice(Math.min(selection.anchor, selection.head), Math.max(selection.anchor, selection.head)) }
    this.positionDirty = true
    this.emit()
    void this.flushPosition()
  }
  private async flushPosition(): Promise<void> {
    if (this.disposed || this.positionFlight || this.mergeFlight || this.pending || !this.positionDirty
      || this.state.connection !== 'connected' || !this.state.sessionId || !this.isCurrent()) return
    const sessionId = this.state.sessionId, position = this.position
    const currentAttempt = this.captureCurrent()
    this.positionDirty = false
    if (this.announcedPosition?.sessionId === sessionId && samePosition(this.announcedPosition.position, position)) return
    const flight = new AbortController()
    this.positionFlight = flight
    try {
      await sendArtifactPresence(this.state.view.draft.target, sessionId, this.workspace, { action: 'position', position }, flight.signal)
      if (currentAttempt() && this.state.sessionId === sessionId) this.announcedPosition = { sessionId, position }
    } catch (error) {
      // A refused/uncertain position is no longer advertised as current.
      if (currentAttempt() && this.state.sessionId === sessionId) {
        this.disconnect()
        this.emit({ message: error instanceof Error ? error.message : '편집 위치를 전달하지 못했습니다.' })
      }
    } finally {
      if (this.positionFlight === flight) {
        this.positionFlight = null
        if (currentAttempt()) void this.flushPosition()
      }
    }
  }
  suspend(): void {
    if (this.disposed) return
    this.lifecycle++
    const merge = this.mergeFlight, position = this.positionFlight
    if (merge) {
      const batch = merge.batch
      this.pending = this.pending ? Y.mergeUpdates([batch, this.pending]) : batch
      this.mergeFlight = null
    }
    // An earlier position belongs only to its old SSE session. Detach it so a
    // stuck response cannot block a new session; its finally owns only its token.
    this.positionFlight = null
    merge?.controller.abort(); position?.abort()
    if (this.pending) this.retain()
    this.connection?.abort(); this.connection = null
    this.announcedPosition = null; this.positionDirty = true
    this.emit({ peers: [], sessionId: null, connection: 'disconnected',
      message: '페이지가 복원되면 다시 연결해 주세요.' })
  }
  dispose(): void {
    if (this.pending || this.mergeFlight) this.retain()
    this.mergeFlight?.controller.abort(); this.positionFlight?.abort()
    this.disconnect(); this.disposed = true
    this.doc.off('update', this.update); this.doc.destroy()
  }
}
