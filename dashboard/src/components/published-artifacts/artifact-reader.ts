import { html } from 'htm/preact'
import { useLayoutEffect, useRef, useState } from 'preact/hooks'
import { artifactHref, type ArtifactDocument, type ArtifactPublication } from '../../api/published-artifacts'
import { Markdown } from '../common/markdown'
import { navigate } from '../../router'
import { copyToClipboard } from '../common/copyable-code'
import type { ArtifactCheckState } from '../../api/published-artifact-checks'
import { ArtifactCheckControl, type ArtifactCheckOutcome } from './artifact-check-control'
import { ArtifactSharedEditor, type ArtifactSharedCloseRequest } from './artifact-shared-editor'
import { ArtifactComposer, type ArtifactPublicationOutcome, type ArtifactDraftRetention, type ArtifactDraftSnapshot } from './artifact-composer'

// Opaque origin: no allow-same-origin. Keep the CSP first so the body cannot
// load subresources before the policy applies. Scripts support self-contained
// interactive reports; no dashboard token or frame messaging bridge is supplied.
export function artifactHtmlDocument(source: string, interactive = true): string {
  return '<!doctype html><meta charset="utf-8">'
    + `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src ${interactive ? "'unsafe-inline'" : "'none'"}; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">`
    + source
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

export function ArtifactReader({ doc, fixedRevision, readError, workspaceRoot, draftRetention, checkState, authRevision, isCurrent, onMutation, onPublication, onPublished, onCheckChanged, onClose }: {
  doc: ArtifactDocument; fixedRevision: boolean; checkState: ArtifactCheckState;
  readError?: string;
  workspaceRoot: string;
  draftRetention: ArtifactDraftRetention;
  authRevision: number; isCurrent: () => boolean; onMutation: (outcome: ArtifactCheckOutcome) => void;
  onPublication: (outcome: ArtifactPublicationOutcome) => void; onPublished: (publication: ArtifactPublication) => void;
  onCheckChanged: () => void; onClose: () => void
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const [view, setView] = useState<'rendered' | 'source'>('rendered')
  const [width, setWidth] = useState<'wide' | 'reading'>('wide')
  const [copyFeedback, setCopyFeedback] = useState('')
  const [editing, setEditing] = useState<{ document: ArtifactDocument; snapshot: ArtifactDraftSnapshot } | null>(null)
  const [sharing, setSharing] = useState<ArtifactDocument | null>(null)
  const sharedCloseRequest = useRef<ArtifactSharedCloseRequest | null>(null)
  const { artifact, content, revisions } = doc
  useLayoutEffect(() => {
    const element = dialog.current!
    element.showModal()
    return () => element.close()
  }, [])
  const changeRevision = (revision: string) => navigate('workspace', {
    section: 'artifacts', artifact: artifact.id,
    ...(revision === 'latest' ? {} : { revision }),
  })
  const copyLink = async () => {
    const href = artifactHref(artifact.id, fixedRevision ? artifact.revision : undefined)
    const success = await copyToClipboard(new URL(href, window.location.href).href, dialog.current ?? undefined)
    setCopyFeedback(success ? '문서 링크를 복사했습니다.' : '링크를 복사하지 못했습니다.')
  }
  const discardDraft = () => window.confirm('작성 중인 원고를 닫을까요? 저장하지 않은 내용은 사라집니다.')
  const close = () => {
    if (editing && !discardDraft()) return
    if (sharing && sharedCloseRequest.current?.().kind !== 'close') return
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
        <div class="flex flex-wrap items-center justify-between gap-2">
          <button type="button" aria-label="목록으로" onClick=${close}>← <span class="hidden sm:inline">목록으로</span></button>
          <h2 id="artifact-reader-title" class="m-0 min-w-0 flex-1 truncate text-base font-semibold">${artifact.title}</h2>
          <div class="flex flex-wrap gap-3 text-xs">
            <button type="button" aria-label="링크 복사" onClick=${copyLink}><span class="sm:hidden">복사</span><span class="hidden sm:inline">링크 복사</span></button>
            <button type="button" aria-label="원본 다운로드" onClick=${() => downloadSource(doc)}><span class="sm:hidden">저장</span><span class="hidden sm:inline">원본 다운로드</span></button>
            <button type="button" aria-label="문서 편집" disabled=${editing !== null || sharing !== null} onClick=${() => {
              const snapshot: ArtifactDraftSnapshot = { identity: {}, base: { id: artifact.id, revision: artifact.revision }, value: {
                title: artifact.title, summary: artifact.summary, format: artifact.format,
                content, task_id: artifact.task_id, goal_id: artifact.goal_id,
              } }
              draftRetention.remember(snapshot)
              setEditing({ document: doc, snapshot })
            }}>편집</button>
            <button type="button" disabled=${editing !== null || sharing !== null} onClick=${() => setSharing(doc)}>공동 편집</button>
          </div>
        </div>
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex items-center gap-3" aria-label="본문 표시 방식">
            <span class="text-xs uppercase text-[var(--color-fg-muted)]">${artifact.format} · v${artifact.revision}</span>
            <button type="button" disabled=${editing !== null || sharing !== null} aria-pressed=${view === 'rendered'} onClick=${() => setView('rendered')}>미리보기</button>
            <button type="button" disabled=${editing !== null || sharing !== null} aria-pressed=${view === 'source'} onClick=${() => setView('source')}>원본</button>
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
        <${ArtifactCheckControl} key=${JSON.stringify([authRevision,artifact.id,artifact.revision,artifact.body._blob.sha256])}
          artifact=${artifact} state=${checkState} authRevision=${authRevision} isCurrent=${isCurrent} onMutation=${onMutation} onChanged=${onCheckChanged} />
        <p role="status" class="m-0 text-xs">${copyFeedback}</p>
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
        ${sharing ? html`<${ArtifactSharedEditor} draftRetention=${draftRetention} doc=${sharing} workspaceRoot=${workspaceRoot} isCurrent=${isCurrent}
          onCloseRequest=${(request: ArtifactSharedCloseRequest | null) => { sharedCloseRequest.current = request }} onMutation=${onPublication} onPublished=${onPublished}
          onClose=${() => { if (sharedCloseRequest.current?.().kind === 'close') setSharing(null) }} />`
          : editing ? html`<${ArtifactComposer} initial=${editing.snapshot.value}
          base=${editing.document} workspaceRoot=${workspaceRoot} isCurrent=${isCurrent} onMutation=${onPublication}
          onDraftChange=${(value: ArtifactDraftSnapshot['value']) => draftRetention.remember({ ...editing.snapshot, value })}
          onSaved=${(publication: ArtifactPublication) => { draftRetention.forget(editing.snapshot.identity); setEditing(null); onPublished(publication) }}
          onCancel=${() => { if (discardDraft()) { draftRetention.forget(editing.snapshot.identity); setEditing(null) } }} />`
          : view === 'source'
          ? html`<pre tabIndex=${0} aria-label="문서 원본" class="m-0 flex-1 whitespace-pre-wrap break-words p-6 text-xs">${content}</pre>`
          : artifact.format === 'markdown'
            ? html`<div class=${`mx-auto w-full min-w-0 p-4 sm:p-8 ${width === 'reading' ? 'max-w-[90ch]' : ''}`}><${Markdown} text=${content} /></div>`
            : html`<iframe title=${artifact.title} sandbox="allow-scripts" referrerPolicy="no-referrer"
                class="min-h-0 w-full flex-1 border-0 bg-white" srcDoc=${artifactHtmlDocument(content)} />`}
      </div>
    </article>
    </dialog>
  `
}
