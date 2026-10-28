import { html } from 'htm/preact'
import { useEffect, useLayoutEffect, useRef, useState } from 'preact/hooks'
import { EditorState, StateEffect, StateField } from '@codemirror/state'
import { Decoration, EditorView, WidgetType, keymap, lineNumbers, type DecorationSet } from '@codemirror/view'
import { yCollab, yUndoManagerKeymap } from 'y-codemirror.next'
import { ApiRequestError } from '../../api/core'
import { sameDraftTarget } from '../../api/artifact-draft-live'
import { checkpointArtifactDraft, sendArtifactDraftCommand, type ArtifactDraftTarget } from '../../api/artifact-drafts'
import { captureArtifactWorkspace, fetchPublishedArtifact, type ArtifactDocument, type ArtifactPublication, type ArtifactWorkspace } from '../../api/published-artifacts'
import { artifactDraftRecoveries, discardArtifactDraftRecovery, type ArtifactDraftRecovery } from '../../lib/artifact-draft-recovery'
import { ArtifactLiveSession, draftBytes, type ArtifactLiveState } from '../../lib/artifact-live-session'
import { resolveSharedSelection, restoreSharedDocument, sharedSource, type SharedSelection } from '../../lib/artifact-shared-document'
import { ArtifactComposer, downloadArtifactDraft, type ArtifactPublicationOutcome, type ArtifactDraftRetention, type ArtifactDraftSnapshot } from './artifact-composer'
import { ArtifactSentenceEditor } from './artifact-sentence-editor'
import { ArtifactDiscussionPanel } from './artifact-discussion-panel'

export type ArtifactSharedCloseResult = { kind: 'keep_open' } | { kind: 'close'; publicationDiscarded: boolean }
export type ArtifactSharedCloseRequest = () => ArtifactSharedCloseResult
type PublicationInput = { base: ArtifactDocument; content: string; owner: ArtifactLiveSession;
  target: ArtifactDraftTarget; expectedSequence: number }

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
function SharedCodeEditor({ session, state, reveal }: { session: ArtifactLiveSession; state: ArtifactLiveState; reveal: SharedSelection | null }) {
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
    return () => { editor.current = null; view.destroy(); session.select(null) }
  }, [session])
  useLayoutEffect(() => {
    const view = editor.current, range = reveal && resolveSharedSelection(session.doc,reveal)
    if (view && range) { view.dispatch({ selection: range, scrollIntoView: true }); view.focus() }
  }, [session,reveal])
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

export function ArtifactSharedEditor({ doc, workspaceRoot, draftRetention, isCurrent, onCloseRequest, onMutation, onPublished, onClose }: {
  doc: ArtifactDocument; workspaceRoot: string; draftRetention: ArtifactDraftRetention; isCurrent: () => boolean; onCloseRequest: (request: ArtifactSharedCloseRequest | null) => void;
  onMutation: (outcome: ArtifactPublicationOutcome) => void; onPublished: (publication: ArtifactPublication) => void; onClose: () => void;
}) {
  const [session, setSession] = useState<ArtifactLiveSession | null>(null)
  const [state, setState] = useState<ArtifactLiveState | null>(null)
  const [error, setError] = useState('')
  const [view, setView] = useState<'source' | 'rendered'>('rendered')
  const [sourceFormat,setSourceFormat]=useState(doc.artifact.format)
  const [visualPending, setVisualPending] = useState(false)
  const [discussionPending, setDiscussionPending] = useState(false)
  const [reveal, setReveal] = useState<SharedSelection | null>(null)
  const resumed = useRef(new Map<string,ArtifactDraftRecovery>())
  const [recoveries, setRecoveries] = useState<ArtifactDraftRecovery[]>([])
  const [comparison, setComparison] = useState<PublicationInput | null>(null)
  const [publication, setPublication] = useState<(PublicationInput & { snapshot: ArtifactDraftSnapshot }) | null>(null)
  const mounted = useRef(true)
  const retired = useRef(false)
  const pageGeneration = useRef(0)
  const [, setPageGeneration] = useState(0)
  const opening = useRef<AbortController | null>(null)
  const openingWorkspace = useRef<ArtifactWorkspace | null>(null)
  const [openingState, setOpeningState] = useState(false)
  const openAgain = useRef<() => void>(() => {})
  const attempted = useRef(new WeakSet<object>())
  const publicationForClose = useRef<ArtifactDraftSnapshot | null>(null)
  const sessionForClose = useRef<ArtifactLiveSession | null>(null)
  const visualPendingForClose = useRef(false)
  const discussionPendingForClose = useRef(false)
  visualPendingForClose.current = visualPending
  discussionPendingForClose.current = discussionPending
  useLayoutEffect(() => {
    // Both Reader navigation and the editor's outer close use one decision.
    // Read refs synchronously instead of a delayed CRDT-only pending effect.
    const request: ArtifactSharedCloseRequest = () => {
      const copy = publicationForClose.current
      if ((copy || sessionForClose.current?.snapshot.pending || visualPendingForClose.current || discussionPendingForClose.current)
        && !window.confirm('이 창에 아직 저장하지 못한 변경이 있습니다. 원고를 닫을까요?')) return { kind: 'keep_open' }
      if (copy) draftRetention.forget(copy.identity)
      publicationForClose.current = null
      retired.current = true
      mounted.current = false
      pageGeneration.current++
      return { kind: 'close', publicationDiscarded: copy !== null }
    }
    onCloseRequest(request)
    const pagehide = () => {
      mounted.current = false
      pageGeneration.current++
      const oldOpening = opening.current
      opening.current = null
      if (oldOpening) { oldOpening.abort(); setOpeningState(false) }
      sessionForClose.current?.suspend()
    }
    const pageshow = () => {
      if (retired.current) return
      mounted.current = true
      setPageGeneration(pageGeneration.current)
    }
    window.addEventListener('pagehide', pagehide)
    window.addEventListener('pageshow', pageshow)
    // Retirement unregisters the close request, preserving the inert snapshot.
    return () => {
      retired.current = true; mounted.current = false; pageGeneration.current++
      window.removeEventListener('pagehide', pagehide); window.removeEventListener('pageshow', pageshow); onCloseRequest(null)
    }
  }, [])
  useEffect(() => {
    let active = true, opened: ArtifactLiveSession | null = null
    const open = async () => {
      if (opening.current || !active || !mounted.current || retired.current || !isCurrent()) return
      const flight = new AbortController()
      opening.current = flight; setOpeningState(true)
      const generation = pageGeneration.current
      const current = () => active && mounted.current && !retired.current && isCurrent() && pageGeneration.current === generation
      try {
        const workspace = await captureArtifactWorkspace(workspaceRoot, flight.signal)
        if (!current()) return
        if (openingWorkspace.current && (openingWorkspace.current.basePath !== workspace.basePath
          || openingWorkspace.current.mascRoot !== workspace.mascRoot)) {
          throw new Error('처음 요청한 작업 공간이 바뀌었습니다. 원고를 다시 열지 않았습니다.')
        }
        openingWorkspace.current = workspace
        const view = await sendArtifactDraftCommand({ action: 'open', artifact_id: doc.artifact.id, revision: doc.artifact.revision }, workspace, flight.signal)
        if (!current()) return
        const base=view.draft.base_revision===doc.artifact.revision?doc
          :await fetchPublishedArtifact(doc.artifact.id,String(view.draft.base_revision),flight.signal,workspace,true)
        if(!current())return
        if(base.artifact.body._blob.sha256!==view.draft.base_sha256)throw new Error('공유 원고의 게시 기준과 원본 문서가 다릅니다.')
        setSourceFormat(base.artifact.format)
        opened = new ArtifactLiveSession(view, workspace, value => { if (active) setState(value) },
          () => isCurrent() && mounted.current && !retired.current)
        sessionForClose.current = opened
        setRecoveries(artifactDraftRecoveries(workspace, doc.artifact.id))
        setSession(opened); setState(opened.snapshot); setError('')
        void opened.connect()
      } catch (reason) {
        if (current()) setError(reason instanceof Error ? reason.message : '공유 원고를 열지 못했습니다.')
      } finally {
        if (opening.current === flight) {
          opening.current = null
          if (active) setOpeningState(false)
        }
      }
    }
    openAgain.current = () => { void open() }
    openAgain.current()
    return () => { active = false; opening.current?.abort(); opening.current = null; openAgain.current = () => {}; sessionForClose.current = null; opened?.dispose() }
  }, [])
  useEffect(() => {
    if(!session)return
    const refresh=()=>setRecoveries(artifactDraftRecoveries(session.workspace,doc.artifact.id))
    window.addEventListener('storage',refresh)
    return ()=>window.removeEventListener('storage',refresh)
  },[session])
  useEffect(() => {
    if (!session || session.snapshot.pending || resumed.current.size === 0) return
    const acknowledged = new Map(resumed.current)
    acknowledged.forEach(discardArtifactDraftRecovery); resumed.current.clear()
    setRecoveries(artifactDraftRecoveries(session.workspace,doc.artifact.id))
  }, [session, state?.pending])
  const draft = (content: string) => ({ title: doc.artifact.title, summary: doc.artifact.summary,
    format: sourceFormat, content, task_id: doc.artifact.task_id, goal_id: doc.artifact.goal_id })
  const preparePublication = (value: PublicationInput) => {
    const artifact = value.base.artifact
    const snapshot: ArtifactDraftSnapshot = { identity: {}, base: { id: artifact.id, revision: artifact.revision },
      value: { ...draft(value.content), title: artifact.title, summary: artifact.summary, format: artifact.format,
        task_id: artifact.task_id, goal_id: artifact.goal_id } }
    // This independent publication copy can diverge from the durable CRDT.
    // Retain it with the same original owner as the ordinary source editor.
    publicationForClose.current = snapshot
    draftRetention.remember(snapshot)
    setPublication({ ...value, snapshot })
  }
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
        discardArtifactDraftRecovery(recovery)
        setRecoveries(values => values.filter(value => value.revision !== recovery.revision))
      } else resumed.current.set(recovery.revision,recovery)
    } catch (reason) { setError(reason instanceof Error ? reason.message : '복구 원고를 읽지 못했습니다.') }
  }
  const publish = async () => {
    if (!session || !state || visualPending || !mounted.current || !session.current) return
    const captured = session.snapshot
    if (captured.pending || captured.connection !== 'connected') return
    // Publication is a frozen snapshot; subsequent shared edits stay in the
    // shared draft. Capture the target and sequence before any async read.
    const content = session.content
    const target = { ...captured.view.draft.target }, expectedSequence = captured.view.draft.sequence
    const generation = pageGeneration.current
    setError('')
    try {
      const latest = await fetchPublishedArtifact(doc.artifact.id, undefined, undefined, session.workspace)
      if (!mounted.current || pageGeneration.current !== generation || !session.current || sessionForClose.current !== session) return
      const input = { base: latest, content, owner: session, target, expectedSequence }
      if (latest.artifact.revision === captured.view.draft.base_revision) preparePublication(input)
      else setComparison(input)
    } catch (reason) {
      if (mounted.current && pageGeneration.current === generation && session.current) setError(reason instanceof Error ? reason.message : '게시할 원고의 원본 버전을 읽지 못했습니다.')
    }
  }
  return html`<section aria-label="문서 공동 편집" class="flex min-h-0 flex-1 flex-col gap-3 p-4">
    <div class="flex flex-wrap items-center gap-4">
      <strong>공동 편집</strong>
      <span role="status">${visualPending ? '아직 반영하지 않은 문장이 있습니다' : state?.connection === 'connected' ? (state.pending ? '원고 저장 중…' : '공유 원고 저장됨')
        : state?.connection === 'disconnected' ? '연결 끊김 · 이 창의 원고 유지' : '연결 중…'}</span>
      ${session ? html`<button type="button" disabled=${visualPending} onClick=${() => downloadArtifactDraft(draft(session.content))}>원고 다운로드</button>` : null}
      ${state?.connection === 'disconnected' ? html`<button type="button" disabled=${state.saving} onClick=${() => { void session?.connect() }}>다시 연결</button>` : null}
      ${!session && !openingState ? html`<button type="button" onClick=${() => openAgain.current()}>공동 편집 다시 열기</button>` : null}
      <button type="button" disabled=${!state || state.pending || visualPending || state.connection !== 'connected' || publication !== null || comparison !== null} onClick=${publish}>새 버전으로 게시</button>
      <button type="button" onClick=${onClose}>공동 편집 닫기</button>
    </div>
    <div class="flex gap-4" aria-label="공동 편집 표시 방식">
      <button type="button" aria-pressed=${view === 'rendered'} onClick=${() => setView('rendered')}>문장 편집</button>
      <button type="button" aria-pressed=${view === 'source'} onClick=${() => {
        if (!visualPending || window.confirm('아직 반영하지 않은 문장이 있습니다. 원본 편집으로 바꿀까요?')) { setVisualPending(false); setView('source') }
      }}>원본 편집</button>
    </div>
    ${state?.pending && !state.recoveryPersisted ? html`<p role="alert">브라우저에 복구 원고를 저장하지 못했습니다. 이 탭을 닫기 전에 원고를 다운로드해 주세요.</p>` : null}
    ${recoveries.map(recovery => html`<details key=${recovery.revision} class="border p-3">
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
      <h3>게시할 공유 원고 · ${sourceFormat}에서 시작</h3>
      <pre class="max-h-40 overflow-auto whitespace-pre-wrap">${comparison.content}</pre>
      <p>최신 게시물의 제목·요약·형식·Task·Goal을 유지합니다. 다음 화면에서 내용을 확인하고 저장해 주세요.</p>
      <button type="button" onClick=${() => { preparePublication(comparison); setComparison(null) }}>이 원고로 새 버전 준비</button>
      <button type="button" onClick=${() => setComparison(null)}>비교 닫기</button>
    </section>` : null}
    ${error || state?.message ? html`<p role="alert">${error || state?.message}</p>` : null}
    ${state ? html`<p class="m-0 text-xs">게시된 v${state.view.draft.base_revision}에서 시작한 공유 원고 · 저장 ${state.view.draft.sequence}회</p>
      <ul aria-label="접속 중인 편집자" class="m-0 flex flex-wrap gap-4 text-xs">
      ${state.peers.map(peer => {
        const range = peer.position && session ? resolveSharedSelection(session.doc, { anchor: [...peer.position.anchor], head: [...peer.position.head] }) : null
        const prefix = range && session ? session.content.slice(0, range.head) : null
        return html`<li key=${peer.session_id}>${peer.source.kind === 'keeper_turn' ? `Keeper · ${peer.actor}` : peer.actor}${peer.session_id === state.sessionId ? ' (이 창)' : ''}
          · ${prefix !== null ? `${prefix.split('\n').length}행 ${prefix.length - prefix.lastIndexOf('\n')}열` : '원고 열람 중'}
          <time class="ml-1 text-[var(--color-fg-muted)]" dateTime=${peer.observed_at}>${new Date(peer.observed_at).toLocaleTimeString()}</time></li>`
      })}</ul>` : null}
    ${session && state ? html`<div class="grid min-h-0 flex-1 gap-4 lg:grid-cols-[minmax(0,2fr)_minmax(18rem,1fr)]">
      <div class="flex min-h-0 min-w-0 flex-col">${view === 'rendered'
        ? html`<${ArtifactSentenceEditor} session=${session} state=${state} format=${sourceFormat} onPending=${setVisualPending} />`
        : html`<${SharedCodeEditor} session=${session} state=${state} reveal=${reveal} />`}</div>
      <div class="min-h-0 min-w-0 overflow-auto"><${ArtifactDiscussionPanel} session=${session} state=${state} onPending=${setDiscussionPending}
        onReveal=${(position:SharedSelection)=>{
          if(visualPending&&!window.confirm('아직 반영하지 않은 문장이 있습니다. 원본에서 댓글 위치를 볼까요?'))return
          setVisualPending(false);setReveal(position);setView('source')
        }} /></div>
    </div>` : null}
    ${publication ? html`<${ArtifactComposer} initial=${publication.snapshot.value} base=${publication.base}
      capturedWorkspace=${publication.owner.workspace} workspaceRoot=${workspaceRoot} isCurrent=${isCurrent} onMutation=${onMutation}
      captureAttempt=${() => { const generation = pageGeneration.current; return () => mounted.current && !retired.current && pageGeneration.current === generation }}
      onDraftChange=${(value: ArtifactDraftSnapshot['value']) => draftRetention.remember({ ...publication.snapshot, value })}
      onSaved=${(value: ArtifactPublication) => {
        if (attempted.current.has(publication.snapshot.identity)) return
        attempted.current.add(publication.snapshot.identity)
        const generation = pageGeneration.current
        const current = () => mounted.current && isCurrent() && publication.owner.current && sessionForClose.current === publication.owner
          && pageGeneration.current === generation && sameDraftTarget(publication.target, publication.owner.snapshot.view.draft.target)
        if (!current()) return
        // Start synchronously under the original authority; navigation can
        // retire it immediately after onPublished. Never send a later retry.
        const attempt = checkpointArtifactDraft(publication.target, publication.expectedSequence, value, publication.owner.workspace)
        const report = (status: 'pending' | 'checkpointed' | 'already_current' | 'refused' | 'unconfirmed', detail?: string) =>
          onMutation({ kind: 'checkpoint', title: value.artifact.title, publication: value, status, detail })
        report('pending')
        void attempt.then(result => {
          if (current()) publication.owner.acceptServerView(result.document)
          report(result.checkpoint)
        }, reason => {
          const detail = reason instanceof Error ? reason.message : '공유 원고 기준 갱신 결과를 확인하지 못했습니다.'
          const status = reason instanceof ApiRequestError ? reason.status : undefined
          // A proxy timeout may arrive after the server committed the request.
          const refused = status !== undefined && status >= 400 && status < 500 && status !== 408
          report(refused ? 'refused' : 'unconfirmed', detail)
          if (current()) setError(`게시 내용은 확인됐지만 공동 원고 기준을 갱신하지 못했습니다: ${detail}`)
        })
        publicationForClose.current = null; draftRetention.forget(publication.snapshot.identity); setPublication(null); onPublished(value)
      }}
      onCancel=${() => {
        if (window.confirm('작성 중인 원고를 닫을까요? 저장하지 않은 내용은 사라집니다.')) {
          publicationForClose.current = null; draftRetention.forget(publication.snapshot.identity); setPublication(null)
        }
      }} />` : null}
  </section>`
}
