import * as Y from 'yjs'
import { sendArtifactDraftCommand, type ArtifactDraftView } from '../api/artifact-drafts'
import { streamArtifactDraft, sendArtifactPresence, type ArtifactDraftPeer, type ArtifactDraftLiveFrame, type ArtifactDraftPosition } from '../api/artifact-draft-live'
import { retainArtifactDraft, discardArtifactDraftRecovery } from './artifact-draft-recovery'
import type { ArtifactWorkspace } from '../api/published-artifacts'
import { restoreSharedDocument, sharedSource, selectSharedSource, type SourceSelection } from './artifact-shared-document'

export function draftBytes(text: string): Uint8Array { return Uint8Array.from(atob(text), char => char.charCodeAt(0)) }
export function draftBase64(bytes: Uint8Array): string { return btoa(Array.from(bytes, byte => String.fromCharCode(byte)).join('')) }
const remote = Symbol('authenticated draft state')
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
  private sending = false
  private positionSending = false
  private position: ArtifactDraftPosition | null = null
  private positionDirty = false
  private connection: AbortController | null = null
  private disposed = false
  private recoveryId = crypto.randomUUID()
  private persisted = true
  constructor(view: ArtifactDraftView, readonly workspace: ArtifactWorkspace, private changed: (state: ArtifactLiveState) => void, private isCurrent: () => boolean = () => true) {
    this.doc = restoreSharedDocument(draftBytes(view.draft.state))
    this.state = { connection: 'connecting', saving: false, pending: false, recoveryPersisted: true, message: '', peers: [], sessionId: null, view }
    this.doc.on('update', this.update)
  }
  get snapshot(): ArtifactLiveState { return this.state }
  get content(): string { return sharedSource(this.doc) }
  private emit(patch: Partial<ArtifactLiveState> = {}): void {
    if (this.disposed) return
    this.state = { ...this.state, ...patch, pending: this.pending !== null || this.sending, saving: this.sending, recoveryPersisted: this.persisted }
    this.changed(this.state)
  }
  private update = (update: Uint8Array, origin: unknown) => {
    if (origin === remote || this.disposed) return
    this.pending = this.pending ? Y.mergeUpdates([this.pending, update]) : update
    this.retain(); this.emit(); void this.flush()
  }
  private retain(): void {
    this.persisted = retainArtifactDraft(this.recoveryId, this.workspace, this.state.view.draft.target, draftBase64(Y.encodeStateAsUpdate(this.doc))).persisted
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
    this.emit({ peers: [], sessionId: null, connection: 'disconnected' })
  }
  private async flush(): Promise<void> {
    if (this.disposed || this.sending || this.state.connection !== 'connected' || !this.isCurrent()) return
    if (!this.pending) { void this.flushPosition(); return }
    const batch = this.pending
    this.pending = null; this.sending = true; this.emit()
    try {
      const view = await sendArtifactDraftCommand({ action: 'merge', target: this.state.view.draft.target, updates: [draftBase64(batch)] }, this.workspace)
      if (!this.disposed) this.receive(view)
    } catch (error) {
      this.pending = this.pending ? Y.mergeUpdates([batch, this.pending]) : batch
      this.disconnect()
      this.emit({ message: error instanceof Error ? error.message : '공유 원고 저장 결과를 확인하지 못했습니다.' })
    } finally {
      this.sending = false
      if (!this.disposed && !this.pending) discardArtifactDraftRecovery(this.recoveryId)
      this.emit()
    }
    if (this.state.connection === 'connected') void this.flush()
  }
  select(selection: SourceSelection | null): void {
    this.position = selection ? selectSharedSource(this.doc, selection) : null
    this.positionDirty = true
    void this.flushPosition()
  }
  private async flushPosition(): Promise<void> {
    if (this.disposed || this.positionSending || this.sending || this.pending || !this.positionDirty
      || this.state.connection !== 'connected' || !this.state.sessionId || !this.isCurrent()) return
    const sessionId = this.state.sessionId, position = this.position
    this.positionDirty = false; this.positionSending = true
    try {
      await sendArtifactPresence(this.state.view.draft.target, sessionId, this.workspace, { action: 'position', position })
    } catch (error) {
      // A refused/uncertain position is no longer advertised as current.
      if (this.state.sessionId === sessionId) {
        this.disconnect()
        this.emit({ message: error instanceof Error ? error.message : '편집 위치를 전달하지 못했습니다.' })
      }
    } finally {
      this.positionSending = false
      if (this.state.sessionId === sessionId) void this.flushPosition()
    }
  }
  dispose(): void {
    if (this.pending || this.sending) this.retain()
    this.disconnect(); this.disposed = true
    this.doc.off('update', this.update); this.doc.destroy()
  }
}
