import { html } from 'htm/preact'
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { EditorState, StateEffect, StateField } from '@codemirror/state'
import { Decoration, EditorView, WidgetType, keymap, lineNumbers, type DecorationSet } from '@codemirror/view'
import { yCollab, yUndoManagerKeymap } from 'y-codemirror.next'
import { sameDraftTarget } from '../../api/artifact-draft-live'
import { sendArtifactDraftCommand } from '../../api/artifact-drafts'
import { captureArtifactWorkspace, fetchPublishedArtifact, type ArtifactDocument, type ArtifactPublication } from '../../api/published-artifacts'
import { artifactDraftRecoveries, discardArtifactDraftRecovery, type ArtifactDraftRecovery } from '../../lib/artifact-draft-recovery'
import { ArtifactLiveSession, draftBytes, type ArtifactLiveState } from '../../lib/artifact-live-session'
import { resolveSharedSelection, restoreSharedDocument, sharedSource } from '../../lib/artifact-shared-document'
import { ArtifactComposer, downloadArtifactDraft, type ArtifactPublicationOutcome } from './artifact-composer'

const remoteSelections = StateEffect.define<DecorationSet>()
const selectionField = StateField.define<DecorationSet>({
  create: () => Decoration.none,
  update(value, transaction) {
    let next = value.map(transaction.changes)
    for (const effect of transaction.effects) if (effect.is(remoteSelections)) next = effect.value
    return next
  }, provide: field => EditorView.decorations.from(field),
})
class PeerCursor extends WidgetType {
  constructor(readonly actor: string) { super() }
  eq(other: PeerCursor) { return other.actor === this.actor }
  toDOM(): HTMLElement {
    const element = document.createElement('span')
    element.className = 'artifact-peer-cursor'; element.textContent = this.actor
    element.setAttribute('aria-label', `${this.actor}의 편집 위치`)
    return element
  }
}
function SharedCodeEditor({ session, state }: { session: ArtifactLiveSession; state: ArtifactLiveState }) {
  const host = useRef<HTMLDivElement>(null), editor = useRef<EditorView | null>(null)
  useLayoutEffect(() => {
    const view = new EditorView({ parent: host.current!, state: EditorState.create({
      doc: session.content,
      extensions: [
        // Explicit LF splitting retains literal CR characters and source offsets
        // in existing CRLF or mixed-ending documents. Never normalize the Y.Text.
        EditorState.lineSeparator.of('\n'), lineNumbers(), EditorView.lineWrapping,
        EditorView.contentAttributes.of({ 'aria-label': '공동 편집 원고' }),
        yCollab(session.doc.getText('content'), null), keymap.of(yUndoManagerKeymap), selectionField,
        EditorView.updateListener.of(update => {
          if (update.selectionSet || update.docChanged || update.focusChanged) {
            const { anchor, head } = update.state.selection.main
            session.select(update.view.hasFocus ? { anchor, head } : null)
          }
        }),
        EditorView.theme({ '&': { minHeight: '20rem', height: '100%' }, '.cm-scroller': { overflow: 'auto' },
          '.artifact-peer-selection': { backgroundColor: '#3699db33' },
          '.artifact-peer-cursor': { borderLeft: '2px solid #1684c9', color: '#075b91', background: '#dff2ff', fontSize: '10px', verticalAlign: 'top' } }),
      ],
    }) })
    editor.current = view
    return () => { editor.current = null; view.destroy() }
  }, [session])
  useLayoutEffect(() => {
    const view = editor.current
    if (!view) return
    const decorations = []
    for (const peer of state.peers) {
      if (peer.session_id === state.sessionId || !peer.position) continue
      const range = resolveSharedSelection(session.doc, { anchor: [...peer.position.anchor], head: [...peer.position.head] })
      if (!range) continue
      const from = Math.min(range.anchor, range.head), to = Math.max(range.anchor, range.head)
      if (from !== to) decorations.push(Decoration.mark({ class: 'artifact-peer-selection', attributes: { title: peer.actor } }).range(from, to))
      decorations.push(Decoration.widget({ widget: new PeerCursor(peer.actor), side: 1 }).range(range.head))
    }
    view.dispatch({ effects: remoteSelections.of(Decoration.set(decorations, true)) })
  }, [session, state])
  return html`<div class="min-h-0 flex-1 border border-[var(--color-border-default)]" ref=${host} />`
}

export function ArtifactSharedEditor({ doc, workspaceRoot, isCurrent, onPending, onMutation, onPublished, onClose }: {
  doc: ArtifactDocument; workspaceRoot: string; isCurrent: () => boolean; onPending: (pending: boolean) => void;
  onMutation: (outcome: ArtifactPublicationOutcome) => void; onPublished: (publication: ArtifactPublication) => void; onClose: () => void;
}) {
  const [session, setSession] = useState<ArtifactLiveSession | null>(null)
  const [state, setState] = useState<ArtifactLiveState | null>(null)
  const [error, setError] = useState('')
  const resumed = useRef(new Set<string>())
  const [recoveries, setRecoveries] = useState<ArtifactDraftRecovery[]>([])
  const [comparison, setComparison] = useState<{ base: ArtifactDocument; content: string } | null>(null)
  const [publication, setPublication] = useState<{ base: ArtifactDocument; content: string } | null>(null)
  useEffect(() => {
    let active = true, opened: ArtifactLiveSession | null = null
    void (async () => {
      const workspace = await captureArtifactWorkspace(workspaceRoot)
      if (!active || !isCurrent()) return
      const view = await sendArtifactDraftCommand({ action: 'open', artifact_id: doc.artifact.id, revision: doc.artifact.revision }, workspace)
      if (!active || !isCurrent()) return
      opened = new ArtifactLiveSession(view, workspace, value => { if (active) setState(value) }, isCurrent)
      setRecoveries(artifactDraftRecoveries(workspace, doc.artifact.id))
      setSession(opened); setState(opened.snapshot)
      void opened.connect()
    })().catch(reason => { if (active) setError(reason instanceof Error ? reason.message : '공유 원고를 열지 못했습니다.') })
    return () => { active = false; opened?.dispose() }
  }, [])
  useEffect(() => { onPending(state?.pending ?? false) }, [state?.pending])
  useEffect(() => {
    if (!session || session.snapshot.pending || resumed.current.size === 0) return
    const acknowledged = new Set(resumed.current)
    acknowledged.forEach(discardArtifactDraftRecovery); resumed.current.clear()
    setRecoveries(values => values.filter(value => !acknowledged.has(value.id)))
  }, [session, state?.pending])
  const draft = (content: string) => ({ title: doc.artifact.title, summary: doc.artifact.summary,
    format: doc.artifact.format, content, task_id: doc.artifact.task_id, goal_id: doc.artifact.goal_id })
  const recoveryContent = (recovery: ArtifactDraftRecovery) => {
    const restored = restoreSharedDocument(draftBytes(recovery.state))
    try { return sharedSource(restored) } finally { restored.destroy() }
  }
  const resume = (recovery: ArtifactDraftRecovery) => {
    if (!session || !sameDraftTarget(recovery.target, session.snapshot.view.draft.target)) return
    try {
      // Validate the saved text schema before handing the update to the editor.
      recoveryContent(recovery)
      session.recover(draftBytes(recovery.state))
      if (session.snapshot.recoveryPersisted || !session.snapshot.pending) {
        discardArtifactDraftRecovery(recovery.id)
        setRecoveries(values => values.filter(value => value.id !== recovery.id))
      } else resumed.current.add(recovery.id)
    } catch (reason) { setError(reason instanceof Error ? reason.message : '복구 원고를 읽지 못했습니다.') }
  }
  const publish = async () => {
    if (!session || !state || state.pending || state.connection !== 'connected' || !isCurrent()) return
    // Publication is a frozen snapshot; subsequent shared edits stay in the
    // shared draft. Capture the latest publication for comparison and CAS.
    const content = session.content
    try {
      const latest = await fetchPublishedArtifact(doc.artifact.id, undefined, undefined, session.workspace)
      if (!isCurrent()) return
      if (latest.artifact.revision === state.view.draft.base_revision) setPublication({ base: latest, content })
      else setComparison({ base: latest, content })
    } catch (reason) { setError(reason instanceof Error ? reason.message : '게시할 원고의 원본 버전을 읽지 못했습니다.') }
  }
  return html`<section aria-label="문서 공동 편집" class="flex min-h-0 flex-1 flex-col gap-3 p-4">
    <div class="flex flex-wrap items-center gap-4">
      <strong>공동 편집</strong>
      <span role="status">${state?.connection === 'connected' ? (state.pending ? '원고 저장 중…' : '공유 원고 저장됨')
        : state?.connection === 'disconnected' ? '연결 끊김 · 이 창의 원고 유지' : '연결 중…'}</span>
      ${session ? html`<button type="button" onClick=${() => downloadArtifactDraft(draft(session.content))}>원고 다운로드</button>` : null}
      ${state?.connection === 'disconnected' ? html`<button type="button" onClick=${() => { void session?.connect() }}>다시 연결</button>` : null}
      <button type="button" disabled=${!state || state.pending || state.connection !== 'connected' || publication !== null || comparison !== null} onClick=${publish}>새 버전으로 게시</button>
      <button type="button" onClick=${onClose}>공동 편집 닫기</button>
    </div>
    ${state?.pending && !state.recoveryPersisted ? html`<p role="alert">브라우저에 복구 원고를 저장하지 못했습니다. 이 탭을 닫기 전에 원고를 다운로드해 주세요.</p>` : null}
    ${recoveries.map(recovery => html`<details key=${recovery.id} class="border p-3">
      <summary>복구 원고 · ${new Date(recovery.at).toLocaleString()}</summary>
      <p>이 브라우저에 남아 있는 원고입니다. 내용을 확인한 뒤 합치거나 다운로드해 주세요.</p>
      <button type="button" onClick=${() => { try { downloadArtifactDraft(draft(recoveryContent(recovery))) } catch (reason) { setError(String(reason)) } }}>복구 원고 다운로드</button>
      <button type="button" disabled=${!session || !sameDraftTarget(recovery.target, session.snapshot.view.draft.target)} onClick=${() => resume(recovery)}>공유 원고에 합치기</button>
      ${session && !sameDraftTarget(recovery.target, session.snapshot.view.draft.target) ? html`<p>공유 원고의 세대가 달라 합칠 수 없습니다. 원고를 다운로드해 주세요.</p>` : null}
    </details>`)}
    ${comparison ? html`<section aria-label="최신 게시물과 원고 비교" class="border p-3">
      <p>최신 게시물은 v${comparison.base.artifact.revision}입니다. 아래 내용을 비교한 뒤 게시할 원고를 준비해 주세요.</p>
      <h3>${comparison.base.artifact.title} · ${comparison.base.artifact.format} · 최신 게시물</h3>
      <pre class="max-h-40 overflow-auto whitespace-pre-wrap">${comparison.base.content}</pre>
      <h3>게시할 공유 원고 · ${doc.artifact.format}에서 시작</h3>
      <pre class="max-h-40 overflow-auto whitespace-pre-wrap">${comparison.content}</pre>
      <p>최신 게시물의 제목·요약·형식·Task·Goal을 유지합니다. 다음 화면에서 내용을 확인하고 저장해 주세요.</p>
      <button type="button" onClick=${() => { setPublication(comparison); setComparison(null) }}>이 원고로 새 버전 준비</button>
      <button type="button" onClick=${() => setComparison(null)}>비교 닫기</button>
    </section>` : null}
    ${error || state?.message ? html`<p role="alert">${error || state?.message}</p>` : null}
    ${state ? html`<p class="m-0 text-xs">게시된 v${state.view.draft.base_revision}에서 시작한 공유 원고 · 저장 ${state.view.draft.sequence}회</p>
      <ul aria-label="접속 중인 편집자" class="m-0 flex flex-wrap gap-4 text-xs">
      ${state.peers.map(peer => {
        const range = peer.position && session ? resolveSharedSelection(session.doc, { anchor: [...peer.position.anchor], head: [...peer.position.head] }) : null
        const prefix = range && session ? session.content.slice(0, range.head) : null
        return html`<li key=${peer.session_id}>${peer.actor}${peer.session_id === state.sessionId ? ' (이 창)' : ''}
          · ${prefix !== null ? `${prefix.split('\n').length}행 ${prefix.length - prefix.lastIndexOf('\n')}열` : '원고 열람 중'}
          <time class="ml-1 text-[var(--color-fg-muted)]" dateTime=${peer.observed_at}>${new Date(peer.observed_at).toLocaleTimeString()}</time></li>`
      })}</ul>` : null}
    ${session && state ? html`<${SharedCodeEditor} session=${session} state=${state} />` : null}
    ${publication ? html`<${ArtifactComposer} initial=${{ ...draft(publication.content), title: publication.base.artifact.title,
      summary: publication.base.artifact.summary, format: publication.base.artifact.format,
      task_id: publication.base.artifact.task_id, goal_id: publication.base.artifact.goal_id }} base=${publication.base}
      capturedWorkspace=${session?.workspace} workspaceRoot=${workspaceRoot} isCurrent=${isCurrent} onMutation=${onMutation}
      onSaved=${(value: ArtifactPublication) => { setPublication(null); onPublished(value) }} onCancel=${() => setPublication(null)} />` : null}
  </section>`
}
