import { html } from 'htm/preact'
import { useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { v7 as uuidV7 } from 'uuid'
import { artifactHref, captureArtifactWorkspace, fetchWorkspacePublishedArtifact, latestArtifactRevision, setPublishedArtifactShared, type ArtifactDocument, type ArtifactPublication, type ArtifactWorkspace, type ArtifactShareResult } from '../../api/published-artifacts'
import { artifactExternalSharing, type ShareObservation } from '../../lib/artifact-external-sharing'
import { forgetPendingShare, retainPendingShare } from '../../lib/artifact-share-recovery'
import { ExternalShareOutcomes } from './external-share-outcomes'
import { PublicationOutcomes } from './publication-outcomes'
import type { ArtifactPublicationOwner } from '../../lib/artifact-publication-outcomes'
import { Markdown } from '../common/markdown'
import { navigate } from '../../router'
import { copyToClipboard } from '../common/copyable-code'
import type { ArtifactCheckState } from '../../api/published-artifact-checks'
import { ArtifactCheckControl, type ArtifactCheckOutcome } from './artifact-check-control'
import { ArtifactSharedEditor, type ArtifactSharedCloseRequest } from './artifact-shared-editor'
import { ArtifactComposer, type ArtifactPublicationOutcome, type ArtifactDraftRetention, type ArtifactDraftSnapshot } from './artifact-composer'
import { ArtifactAppView } from './artifact-app-view'
import { artifactAppFrame, appFrameMessage } from '../../lib/artifact-app-frame'
import { ArtifactWordExport } from './artifact-word-export'
import { ArtifactPptxExport } from './artifact-pptx-export'
import { ArtifactPdfExport } from './artifact-pdf-export'

function ReadOnlyArtifactFrame({ doc, interactive }: { doc: ArtifactDocument; interactive: boolean }) {
  const iframe = useRef<HTMLIFrameElement>(null)
  const frame = useMemo(() => artifactAppFrame(doc.content, []), [doc.content])
  useLayoutEffect(() => {
    const receive = (event: MessageEvent) => {
      if (event.source !== iframe.current?.contentWindow) return
      const message = appFrameMessage(frame, event.data)
      if (message?.kind === 'ready') {
        iframe.current?.contentWindow?.postMessage(
          { type: 'masc.artifact.inputs.init.v1', token: frame.token, instance: message.instance, data: { forms: {}, app: {} } },
          '*',
        )
      }
    }
    window.addEventListener('message', receive)
    return () => window.removeEventListener('message', receive)
  }, [frame])
  return html`<iframe ref=${iframe} title=${doc.artifact.title} sandbox=${interactive ? 'allow-scripts' : ''}
    inert=${interactive ? undefined : true} tabIndex=${interactive ? undefined : -1} referrerPolicy="no-referrer"
    class=${`min-h-0 w-full flex-1 border-0 bg-white ${interactive ? '' : 'pointer-events-none'}`} srcDoc=${frame.document} />`
}

function downloadSource(doc: ArtifactDocument): void {
  const { artifact, content } = doc
  const extension = artifact.format === 'html' ? 'html' : 'md'
  // Encode first to avoid Blob's platform newline conversion.
  const blob = new Blob([new TextEncoder().encode(content)], { type: `text/${artifact.format};charset=utf-8` })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = `${artifact.id}-v${artifact.revision}.${extension}`
  anchor.click()
  URL.revokeObjectURL(url)
}

export type ArtifactShareSelection = { doc: ArtifactDocument; fixedRevision: boolean; readError?: string; revalidating?: boolean; shareWorkspace?: ArtifactWorkspace }

export function ArtifactReader({ doc, fixedRevision, readOnly = false, readOnlyInteractive = true, readOnlyLabel = '외부 공유 열람', readError, workspaceRoot, shareWorkspace, currentShareSelection, waitForShareSelection, draftRetention, checkState, authRevision, isCurrent, onMutation, onPublication, onPublished, onCheckChanged, shareObservation, onClose, publicationOwner, onDialogState }: {
  doc: ArtifactDocument; fixedRevision: boolean; checkState: ArtifactCheckState;
  publicationOwner?: ArtifactPublicationOwner; onDialogState?: (open: boolean) => void;
  readOnly?: boolean;
  readOnlyInteractive?: boolean;
  readOnlyLabel?: string;
  readError?: string;
  shareObservation?: ShareObservation;
  shareWorkspace?: ArtifactWorkspace;
  currentShareSelection?: () => ArtifactShareSelection | undefined;
  waitForShareSelection?: () => Promise<ArtifactShareSelection | undefined>;
  workspaceRoot: string;
  draftRetention: ArtifactDraftRetention;
  authRevision: number; isCurrent: () => boolean; onMutation: (outcome: ArtifactCheckOutcome) => void;
  onPublication: (outcome: ArtifactPublicationOutcome) => void; onPublished: (publication: ArtifactPublication, workspace: ArtifactWorkspace) => void;
  onCheckChanged: () => void; onClose: () => void
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [view, setView] = useState<'rendered' | 'source'>('rendered')
  const [width, setWidth] = useState<'wide' | 'reading'>('wide')
  const [copyFeedback, setCopyFeedback] = useState('')
  const [editing, setEditing] = useState<{ document: ArtifactDocument; snapshot: ArtifactDraftSnapshot; workspace: ArtifactWorkspace } | null>(null)
  const [sharing, setSharing] = useState<{ document: ArtifactDocument; workspace: ArtifactWorkspace } | null>(null)
  const sharedCloseRequest = useRef<ArtifactSharedCloseRequest | null>(null)
  const appPending=useRef(false)
  const active = useRef(true)
  const selection = useRef<ArtifactShareSelection>({ doc, fixedRevision, readError, shareWorkspace })
  selection.current = { doc, fixedRevision, readError, shareWorkspace }
  const { artifact, content, revisions } = doc
  const observedLatest = latestArtifactRevision(doc)
  const shareActivity = shareWorkspace ? artifactExternalSharing.activity(artifact.id, shareWorkspace) : undefined
  const sharedState = doc.share_version !== undefined && observedLatest && shareObservation && shareWorkspace && !readError && shareActivity === 'ready'
    && shareObservation.id === artifact.id && shareObservation.workspace.basePath === shareWorkspace.basePath
    && shareObservation.workspace.mascRoot === shareWorkspace.mascRoot
    && artifactExternalSharing.admits(shareObservation) ? doc.shared : undefined
  const current = () => active.current && isCurrent()
  useLayoutEffect(() => () => { active.current = false }, [])
  useLayoutEffect(() => {
    const element = dialog.current!
    element.showModal()
    onDialogState?.(true)
    return () => { element.close(); onDialogState?.(false) }
  }, [])
  const leaveApp=(action:()=>void)=>{if(!appPending.current||window.confirm('아직 저장하지 못한 앱 입력이 있습니다. 이 화면을 나갈까요?'))action()}
  const changeRevision = (revision: string) => leaveApp(()=>navigate('workspace', {
    section: 'artifacts', artifact: artifact.id,
    ...(revision === 'latest' ? {} : { revision }),
  }))
  const copyLink = async () => {
    const href = artifactHref(artifact.id, artifact.revision)
    const success = await copyToClipboard(new URL(href, window.location.href).href, dialog.current ?? undefined)
    setCopyFeedback(success ? `현재 접속 주소 ${window.location.origin} 기준으로 문서 링크를 복사했습니다.` : '링크를 복사하지 못했습니다.')
  }
  const toggleExternalShare = async () => {
    if (!current() || !shareObservation || !shareWorkspace || sharedState === undefined) return
    const observed = () => currentShareSelection ? currentShareSelection() : selection.current
    const sameVisit = () => {
      const view = observed()
      return current() && view?.fixedRevision === fixedRevision && view.doc.artifact.id === artifact.id
        && view.shareWorkspace?.basePath === shareWorkspace.basePath
        && view.shareWorkspace.mascRoot === shareWorkspace.mascRoot
    }
    const stillSelected = () => {
      const view = observed()
      return sameVisit() && view?.doc.artifact.revision === artifact.revision
        && view.doc.artifact.body._blob.sha256 === artifact.body._blob.sha256
    }
    const canDispatch = () => {
      const view = observed()
      return stillSelected() && view !== undefined && !view.readError && !view.revalidating
        && view.doc.shared === sharedState && view.doc.share_version === doc.share_version
        && latestArtifactRevision(view.doc)?.revision === observedLatest?.revision
        && latestArtifactRevision(view.doc)?.body._blob.sha256 === observedLatest?.body._blob.sha256
    }
    const nextShared = !sharedState
    const owner = artifactExternalSharing.begin(artifact.id, shareWorkspace, shareObservation)
    if (!owner) return
    setCopyFeedback('')
    const notSent = (message: string) => {
      if (sameVisit()) setCopyFeedback(message)
      artifactExternalSharing.finish(artifact.id, shareWorkspace, owner, 'not-sent')
    }
    const changed = '문서 또는 공유 상태가 달라졌거나 확인할 수 없어 요청을 보내지 않았습니다. 다시 확인해 주세요.'
    const workspace = shareWorkspace
    try {
      const currentWorkspace = await captureArtifactWorkspace(workspaceRoot)
      if (currentWorkspace.basePath !== workspace.basePath || currentWorkspace.mascRoot !== workspace.mascRoot) {
        notSent(changed)
        return
      }
      if (!canDispatch()) { notSent(changed); return }
      const fresh = await fetchWorkspacePublishedArtifact(artifact.id, fixedRevision ? String(artifact.revision) : undefined, workspace)
      if (!canDispatch()) { notSent(changed); return }
      if (fresh.artifact.revision !== artifact.revision || fresh.shared !== sharedState || fresh.share_version !== doc.share_version
        || fresh.artifact.body._blob.sha256 !== artifact.body._blob.sha256
        || latestArtifactRevision(fresh)?.revision !== observedLatest?.revision
        || latestArtifactRevision(fresh)?.body._blob.sha256 !== observedLatest?.body._blob.sha256) {
        notSent(changed)
        return
      }
    } catch (error) {
      notSent(error instanceof Error ? `공유 상태를 확인하지 못해 요청을 보내지 않았습니다: ${error.message}` : '공유 상태를 확인하지 못해 요청을 보내지 않았습니다.')
      return
    }
    if (doc.share_version === undefined || !observedLatest) { notSent(changed); return }
    const operation = { id: artifact.id, operationId: uuidV7(), expectedVersion: doc.share_version, shared: nextShared,
      expectedArtifactRevision: observedLatest.revision, expectedArtifactSha256: observedLatest.body._blob.sha256 }
    const pending = { operation, workspace, title: artifact.title, revision: artifact.revision }
    const receipt = { id: artifact.id, title: artifact.title, revision: artifact.revision, requested: nextShared, workspace,
      operationId: operation.operationId, expectedVersion: operation.expectedVersion, operation }
    artifactExternalSharing.attachPending(artifact.id, workspace, owner, pending)
    const retainUnconfirmed = (detail: string) => {
      artifactExternalSharing.finish(artifact.id, workspace, owner, { ...receipt, kind: 'unconfirmed', detail, pending })
      if (sameVisit()) setCopyFeedback(detail)
    }
    try { retainPendingShare(pending) } catch {
      // A failed readback can follow a successful write that another tab saw.
      retainUnconfirmed('이 탭은 요청을 보내지 않았지만, 보관 결과와 다른 탭의 시도는 미확인입니다.')
      return
    }
    if (!canDispatch()) {
      // Another tab can see the retained operation before this tab dispatches.
      retainUnconfirmed('이 탭은 요청을 보내지 않았지만, 같은 작업의 다른 탭 시도는 미확인입니다.')
      return
    }
    let updated: ArtifactShareResult
    try {
      updated = await setPublishedArtifactShared(operation, workspace)
    } catch (error) {
      const detail = error instanceof Error ? error.message : '외부 공유 변경 결과를 확인하지 못했습니다.'
      artifactExternalSharing.finish(artifact.id, workspace, owner, { ...receipt, kind: 'unconfirmed', detail, pending })
      if (!stillSelected()) return
      setCopyFeedback(`외부 공유 변경 결과 미확인: ${detail}`)
      return
    }
    forgetPendingShare(pending)
    artifactExternalSharing.finish(artifact.id, workspace, owner, { ...receipt, kind: 'confirmed',
      outcome: updated.receipt.outcome, shared: updated.receipt.snapshot.shared, current: updated.current.shared })
    if (!stillSelected()) return
    if (updated.receipt.outcome === 'conflict') {
      setCopyFeedback(updated.receipt.publication_matches
        ? '공유 상태가 다른 요청으로 바뀌어 적용되지 않았습니다. 현재 상태를 다시 확인해 주세요.'
        : '문서의 최신 버전이 바뀌어 공유 요청을 적용하지 않았습니다. 문서를 다시 확인해 주세요.')
    } else if (nextShared && updated.current.shared) {
      const known = observed()?.doc
      if (!known) return
      if (known.share_version !== undefined && (known.share_version > updated.current.version
        || (known.share_version === updated.current.version && known.shared !== updated.current.shared))) {
        setCopyFeedback('요청이 적용된 뒤 더 새로운 공유 상태를 읽었습니다. 다시 확인해 주세요.')
        return
      }
      // A local write started during the verification read also retires this
      // copy, even if that write has already finished by the time it returns.
      const copyObservation = artifactExternalSharing.observe(artifact.id, workspace)
      let verified: ArtifactDocument
      try { verified = await fetchWorkspacePublishedArtifact(artifact.id, fixedRevision ? String(artifact.revision) : undefined, workspace) }
      catch { if (stillSelected()) setCopyFeedback('요청은 적용됐지만 현재 공유 상태를 확인하지 못했습니다.'); return }
      if (!stillSelected()) return
      while (observed()?.revalidating && stillSelected()) {
        if (!waitForShareSelection) return
        setCopyFeedback('요청은 적용됐습니다. 진행 중인 공유 상태 확인을 기다리고 있습니다.')
        if (!await waitForShareSelection()) {
          if (stillSelected()) setCopyFeedback('공유 상태 확인이 중단되어 링크를 복사하지 못했습니다. 다시 확인해 주세요.')
          return
        }
      }
      if (!stillSelected()) return
      const latestView = observed()
      const latestKnown = latestView?.doc
      if (!latestView || !latestKnown || latestView.readError || latestView.revalidating || latestKnown.share_version === undefined || latestKnown.shared === undefined
        || !artifactExternalSharing.admits(copyObservation)
        || verified.shared !== true || verified.share_version === undefined || verified.share_version < updated.current.version
        || latestKnown.share_version > verified.share_version
        || (latestKnown.share_version === verified.share_version && latestKnown.shared !== verified.shared)) {
        setCopyFeedback('요청 이후 공유 상태가 바뀌었거나 확인되지 않아 링크를 복사하지 않았습니다.')
        return
      }
      const href = artifactHref(artifact.id, artifact.revision)
      const copied = await copyToClipboard(new URL(href, window.location.href).href, dialog.current ?? undefined)
      if (stillSelected()) setCopyFeedback(copied ? `공유 상태를 확인하고 현재 접속 주소 ${window.location.origin} 기준 링크를 복사했습니다.` : '공유 상태를 확인했지만 링크를 복사하지 못했습니다.')
    } else if (!nextShared && !updated.current.shared) {
      setCopyFeedback('외부 공유 해제 요청이 적용됐습니다. 응답 시점에는 공유가 꺼져 있었습니다.')
    } else {
      setCopyFeedback('요청은 적용됐지만 이후 공유 상태가 다시 변경됐습니다. 현재 상태를 확인해 주세요.')
    }
  }
  const discardDraft = () => window.confirm('작성 중인 원고를 닫을까요? 저장하지 않은 내용은 사라집니다.')
  const close = () => {
    if (editing && !discardDraft()) return
    if (sharing && sharedCloseRequest.current?.().kind !== 'close') return
    if (appPending.current && !window.confirm('아직 저장하지 못한 앱 입력이 있습니다. 문서를 닫을까요?'))return
    if (editing) draftRetention.forget(editing.snapshot.identity)
    onClose()
  }
  return html`
    <dialog ref=${dialog} aria-labelledby="artifact-reader-title"
      class="fixed inset-0 m-0 h-dvh max-h-none w-full max-w-none overflow-hidden border-0 bg-[var(--color-bg-surface)] p-0 text-[var(--color-fg-default)]"
      onKeyDown=${(event: KeyboardEvent) => {
        // Let the native dialog handle Escape before the shell's chat shortcut.
        if (event.key === 'Escape') event.stopPropagation()
      }}
      onCancel=${(event: Event) => { event.preventDefault(); close() }}>
    <article class="flex h-full min-w-0 flex-col" aria-label="아티팩트 본문">
      <header class="shrink-0 border-b border-[var(--color-border-default)] px-4 py-3 space-y-2">
        ${readError ? html`<p role="alert">문서 재조회 실패: ${readError} 이전에 읽은 문서와 작성 중인 원고를 유지합니다.</p>` : null}
        <${ExternalShareOutcomes} />
        <${PublicationOutcomes} currentOwner=${publicationOwner} />
        <div class="flex flex-wrap items-center justify-between gap-2">
          ${readOnly
            ? html`<button type="button" onClick=${close}>닫기</button>`
            : html`<button type="button" aria-label="목록으로" onClick=${close}>← <span class="hidden sm:inline">목록으로</span></button>`}
          ${readOnly ? html`<span class="rounded border border-[var(--color-border-default)] px-2 py-0.5 text-xs text-[var(--color-fg-secondary)]">${readOnlyLabel}</span>` : null}
          <h2 id="artifact-reader-title" class="m-0 min-w-0 flex-1 truncate text-base font-semibold">${artifact.title}</h2>
          <div class="flex flex-wrap gap-3 text-xs">
            <button type="button" aria-label="링크 복사" onClick=${copyLink}><span class="sm:hidden">복사</span><span class="hidden sm:inline">링크 복사</span></button>
            <button type="button" aria-label="원본 다운로드" onClick=${() => downloadSource(doc)}><span class="sm:hidden">저장</span><span class="hidden sm:inline">원본 다운로드</span></button>
            ${readOnly ? null : html`
              <button type="button" aria-label=${sharedState === undefined ? '외부 공유 상태 미확인' : sharedState ? '외부 공유 해제' : '외부 공유 켜기'}
                aria-pressed=${sharedState} disabled=${sharedState === undefined || editing !== null || sharing !== null}
                onClick=${toggleExternalShare}>${shareActivity === 'pending' ? '외부 공유 변경 중…'
                  : shareActivity === 'unconfirmed' ? '외부 공유 결과 미확인'
                  : sharedState === undefined ? '외부 공유 상태 미확인' : sharedState ? '외부 공유 중' : '외부 공유 켜기'}</button>
              <span>외부 공유는 이 문서의 모든 버전에 적용됩니다.</span>
              ${shareActivity === 'unconfirmed' ? html`<span>요청이 나중에 적용될 수 있어 이 탭에서는 공유 상태를 다시 변경할 수 없습니다.</span>` : null}
              <button type="button" aria-label="문서 편집" disabled=${!!readError || editing !== null || sharing !== null} onClick=${() => leaveApp(() => {
                if (!shareWorkspace || readError) return
                const snapshot: ArtifactDraftSnapshot = { identity: {}, base: { id: artifact.id, revision: artifact.revision }, value: {
                  title: artifact.title, summary: artifact.summary, format: artifact.format,
                  content, task_id: artifact.task_id, goal_id: artifact.goal_id,
                } }
                draftRetention.remember(snapshot)
                setEditing({ document: doc, snapshot, workspace: shareWorkspace })
              })}>편집</button>
              <button type="button" disabled=${!!readError || editing !== null || sharing !== null} onClick=${() => leaveApp(()=>{
                if (shareWorkspace && !readError) setSharing({ document: doc, workspace: shareWorkspace })
              })}>공동 편집</button>
            `}
          </div>
        </div>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-center gap-3" aria-label="본문 표시 방식">
            <span class="text-xs uppercase text-[var(--color-fg-muted)]">${artifact.format} · v${artifact.revision}</span>
            <button type="button" disabled=${editing !== null || sharing !== null} aria-pressed=${view === 'rendered'} onClick=${() => setView('rendered')}>미리보기</button>
            <button type="button" disabled=${editing !== null || sharing !== null} aria-pressed=${view === 'source'} onClick=${() => leaveApp(()=>setView('source'))}>원본</button>
            ${artifact.format === 'markdown' && view === 'rendered' ? html`
              <button type="button" aria-pressed=${width === 'wide'}
                onClick=${() => setWidth(value => value === 'wide' ? 'reading' : 'wide')}>
                ${width === 'wide' ? '넓은 폭' : '읽기 폭'}
              </button>` : null}
          </div>
          <label class="flex min-w-0 items-center gap-1 text-xs">버전 ${' '}
            <select aria-label="문서 버전" disabled=${editing !== null || sharing !== null} value=${fixedRevision ? String(artifact.revision) : 'latest'}
              onChange=${(event: Event) => changeRevision((event.target as HTMLSelectElement).value)}>
              <option value="latest">최신 버전</option>
              ${revisions.map(r => html`<option key=${r.revision} value=${String(r.revision)}>v${r.revision} · ${r.author} · ${new Date(r.created_at).toLocaleString()}</option>`)}
            </select>
          </label>
        </div>
        ${readOnly ? null : html`<${ArtifactCheckControl} key=${JSON.stringify([authRevision,artifact.id,artifact.revision,artifact.body._blob.sha256])}
          artifact=${artifact} state=${readError ? { kind: 'unknown', message: readError } : checkState} authRevision=${authRevision} isCurrent=${isCurrent} onMutation=${onMutation} onChanged=${onCheckChanged} />`}
        <${ArtifactWordExport} key=${JSON.stringify([authRevision,workspaceRoot,artifact.id,artifact.revision,artifact.body._blob.sha256])}
          doc=${doc} authRevision=${authRevision} isCurrent=${isCurrent} disabled=${editing!==null||sharing!==null} />
        <${ArtifactPptxExport} key=${JSON.stringify(['pptx',authRevision,workspaceRoot,artifact.id,artifact.revision,artifact.body._blob.sha256])}
          doc=${doc} authRevision=${authRevision} isCurrent=${isCurrent} disabled=${editing!==null||sharing!==null} />
        <${ArtifactPdfExport} key=${JSON.stringify(['pdf',authRevision,workspaceRoot,artifact.id,artifact.revision,artifact.body._blob.sha256])}
          doc=${doc} authRevision=${authRevision} isCurrent=${isCurrent} disabled=${editing!==null||sharing!==null} />
        <p role="status" class="m-0 text-xs">${copyFeedback}</p>
        ${readOnly && !readOnlyInteractive && artifact.format === 'html' && view === 'rendered'
          ? html`<p class="m-0 text-xs">작업 공간 확인 전에는 HTML 스크립트를 실행하지 않습니다. 내용이 보이지 않으면 원본을 확인해 주세요.</p>` : null}
        <details class="text-xs text-[var(--color-fg-secondary)]">
          <summary class="cursor-pointer">보고서 정보</summary>
          <p class="my-2">${artifact.summary}</p>
          <div class="flex flex-wrap items-center gap-3">
            <a href=${`#/keepers?keeper=${encodeURIComponent(artifact.author)}`}>${artifact.author}</a>
            <time dateTime=${artifact.created_at}>${new Date(artifact.created_at).toLocaleString()}</time>
            ${artifact.task_id ? html`<a href=${`#/workspace?section=planning&task=${encodeURIComponent(artifact.task_id)}`}>${artifact.task_id}</a>` : null}
            ${artifact.goal_id ? html`<a href=${`#/workspace?section=planning&goal=${encodeURIComponent(artifact.goal_id)}`}>${artifact.goal_id}</a>` : null}
          </div>
        </details>
      </header>
      <div class="flex min-h-0 min-w-0 flex-1 flex-col overflow-auto">
        ${sharing ? html`<${ArtifactSharedEditor} draftRetention=${draftRetention} doc=${sharing.document} workspaceRoot=${workspaceRoot} capturedWorkspace=${sharing.workspace} isCurrent=${isCurrent}
          onCloseRequest=${(request: ArtifactSharedCloseRequest | null) => { sharedCloseRequest.current = request }} onMutation=${onPublication} onPublished=${onPublished}
          onClose=${() => { if (sharedCloseRequest.current?.().kind === 'close') setSharing(null) }} />`
          : editing ? html`<${ArtifactComposer} initial=${editing.snapshot.value}
          base=${editing.document} workspaceRoot=${workspaceRoot} capturedWorkspace=${editing.workspace} isCurrent=${isCurrent} onMutation=${onPublication}
          onDraftChange=${(value: ArtifactDraftSnapshot['value']) => draftRetention.remember({ ...editing.snapshot, value })}
          onSaved=${(publication: ArtifactPublication, workspace: ArtifactWorkspace) => { draftRetention.forget(editing.snapshot.identity); setEditing(null); onPublished(publication, workspace) }}
          onCancel=${() => { if (discardDraft()) { draftRetention.forget(editing.snapshot.identity); setEditing(null) } }} />`
          : view === 'source'
          ? html`<pre tabIndex=${0} aria-label="문서 원본" class="m-0 flex-1 whitespace-pre-wrap break-words p-6 text-xs">${content}</pre>`
          : artifact.format === 'markdown'
            ? html`<div class=${`mx-auto w-full min-w-0 p-4 sm:p-8 ${width === 'reading' ? 'max-w-[90ch]' : ''}`}><${Markdown} text=${content} /></div>`
            : readOnly
              ? html`<${ReadOnlyArtifactFrame} key=${JSON.stringify([artifact.id, artifact.revision, artifact.body._blob.sha256])} doc=${doc} interactive=${readOnlyInteractive} />`
              : shareWorkspace ? html`<${ArtifactAppView} key=${JSON.stringify([authRevision,shareWorkspace.basePath,shareWorkspace.mascRoot,artifact.id,artifact.revision,artifact.body._blob.sha256])}
                doc=${doc} capturedWorkspace=${shareWorkspace} authRevision=${authRevision} isCurrent=${isCurrent} onPending=${(pending:boolean)=>{appPending.current=pending}} />` : null}
      </div>
    </article>
    </dialog>
  `
}
