import { html } from 'htm/preact'
import { useEffect, useRef, useState } from 'preact/hooks'
import { ApiRequestError } from '../../api/core'
import {
  publishArtifact, readPublishedDraft, fetchPublishedArtifact, artifactHref, captureArtifactWorkspace,
  type ArtifactDocument, type ArtifactDraft, type ArtifactPublication, type ArtifactPublicationRequest, type ArtifactWorkspace,
} from '../../api/published-artifacts'

export type ArtifactPublicationOutcome = { title: string; base?: { id: string; revision: number } } & (
  | { kind: 'published'; publication: ArtifactPublication; verified: boolean }
  | { kind: 'unconfirmed'; detail: string }
  | { kind: 'checkpoint'; publication: ArtifactPublication;
      status: 'pending' | 'checkpointed' | 'already_current' | 'refused' | 'unconfirmed'; detail?: string }
)
export type ArtifactDraftSnapshot = {
  readonly identity: object;
  readonly value: ArtifactDraft;
  readonly base?: { readonly id: string; readonly revision: number };
}
export type ArtifactDraftRetention = {
  remember: (snapshot: ArtifactDraftSnapshot) => void;
  forget: (identity: object) => void;
}
type SaveState = { kind: 'ready'; message?: string } | { kind: 'saving' }
  | { kind: 'conflict'; message: string; latest?: ArtifactDocument }
  | { kind: 'unconfirmed'; message: string; publication?: ArtifactPublication }
  | { kind: 'saved'; publication: ArtifactPublication; message?: string }
type WorkspaceState = { kind: 'loading' } | { kind: 'ready'; value: ArtifactWorkspace } | { kind: 'error'; message: string }

export function downloadArtifactDraft(draft: ArtifactDraft) {
  const blob = new Blob([new TextEncoder().encode(draft.content)], { type: `${draft.format === 'html' ? 'text/html' : 'text/markdown'};charset=utf-8` })
  const url = URL.createObjectURL(blob)
  const anchor = document.createElement('a')
  anchor.href = url
  anchor.download = `artifact-draft.${draft.format === 'html' ? 'html' : 'md'}`
  anchor.click()
  URL.revokeObjectURL(url)
}

export function ArtifactComposer({ initial, base, workspaceRoot, isCurrent, onDraftChange, onMutation, onSaved, onCancel, capturedWorkspace, captureAttempt }: {
  initial: ArtifactDraft; base?: ArtifactDocument; capturedWorkspace?: ArtifactWorkspace; isCurrent: () => boolean;
  captureAttempt?: () => () => boolean;
  workspaceRoot: string;
  onDraftChange: (draft: ArtifactDraft) => void;
  onMutation: (outcome: ArtifactPublicationOutcome) => void;
  onSaved: (publication: ArtifactPublication) => void; onCancel: () => void;
}) {
  const [draft, setDraft] = useState(initial)
  const latestDraft = useRef(initial)
  const updateDraft = (change: Partial<ArtifactDraft>) => {
    const next = { ...latestDraft.current, ...change }
    latestDraft.current = next
    setDraft(next)
    // Capture synchronously: retirement may unmount us before an effect runs.
    onDraftChange(next)
  }
  const [state, setState] = useState<SaveState>({ kind: 'ready' })
  const [latestError, setLatestError] = useState('')
  const active = useRef(true)
  const sending = useRef(false)
  const [workspace, setWorkspace] = useState<WorkspaceState>({ kind: 'loading' })
  const baseRef = base ? { id: base.artifact.id, revision: base.artifact.revision } : undefined
  useEffect(() => () => { active.current = false }, [])
  const current = () => active.current && isCurrent()
  useEffect(() => {
    // Freeze both canonical roots when the editable draft is created. Never
    // recapture under another root after a failed read or a server switch.
    if (capturedWorkspace) { setWorkspace({ kind: 'ready', value: capturedWorkspace }); return }
    void captureArtifactWorkspace(workspaceRoot).then(value => {
      if (current()) setWorkspace({ kind: 'ready', value })
    }, error => {
      if (current()) setWorkspace({ kind: 'error', message: error instanceof Error ? error.message : '작업 공간을 확인하지 못했습니다.' })
    })
  }, [])
  const ready = state.kind === 'ready' || state.kind === 'conflict'
  const save = async () => {
    if (sending.current || state.kind !== 'ready' || workspace.kind !== 'ready' || !current()) return
    const attemptCurrent = captureAttempt?.() ?? (() => true)
    if (!attemptCurrent()) return
    sending.current = true
    const sent = { ...draft }
    const request: ArtifactPublicationRequest = base
      ? { ...sent, id: base.artifact.id, expected_revision: base.artifact.revision }
      : sent
    setState({ kind: 'saving' })
    const expectedWorkspace = workspace.value
    let publication: ArtifactPublication
    try {
      publication = await publishArtifact(request, expectedWorkspace)
    } catch (error) {
      const message = error instanceof Error ? error.message : '저장 응답을 받지 못했습니다.'
      // A proxy timeout can arrive after the server has committed. Preserve
      // the uncertain publication without offering another save in this editor.
      const refusalStatus = error instanceof ApiRequestError ? error.status : undefined
      const definiteRefusal = refusalStatus !== undefined && refusalStatus >= 400 && refusalStatus < 500 && refusalStatus !== 408
      if (definiteRefusal && error instanceof ApiRequestError && error.errorCode === 'workspace_precondition_failed') {
        sending.current = false
        if (current()) setState({ kind: 'ready', message: '서버의 작업 공간이 바뀌어 저장 요청이 거절되었습니다. 작성한 원고는 그대로 남아 있습니다.' })
        return
      }
      sending.current = false
      if (!definiteRefusal) onMutation({ kind: 'unconfirmed', title: sent.title, base: baseRef, detail: message })
      if (!current()) return
      if (refusalStatus === 409) setState({ kind: 'conflict', message: '다른 사용자가 먼저 저장했습니다. 작성한 원고는 그대로 남아 있습니다.' })
      else if (definiteRefusal) setState({ kind: 'ready', message })
      else setState({ kind: 'unconfirmed', message })
      return
    }
    // Keep the committed identity even if the selected document/workspace was
    // withdrawn while the request was in flight. Do not read with new credentials.
    onMutation({ kind: 'published', title: sent.title, base: baseRef, publication, verified: false })
    if (!current() || !attemptCurrent()) {
      sending.current = false
      if (current()) setState({ kind: 'unconfirmed', publication,
        message: '페이지가 바뀌기 전에 보낸 게시 응답입니다. 저장된 버전을 직접 확인해 주세요.' })
      return
    }
    try {
      await readPublishedDraft(publication, sent, expectedWorkspace)
      onMutation({ kind: 'published', title: sent.title, base: baseRef, publication, verified: true })
      if (!current()) return
      if (attemptCurrent()) { setState({ kind: 'saved', publication }); onSaved(publication) }
      else setState({ kind: 'saved', publication,
        message: '게시된 내용은 확인했습니다. 페이지가 바뀌어 공동 원고 기준은 자동으로 갱신하지 않았습니다.' })
    } catch (error) {
      if (!current()) return
      setState({ kind: 'unconfirmed', publication, message: error instanceof Error ? error.message : '저장한 버전을 다시 읽지 못했습니다.' })
    } finally {
      sending.current = false
    }
  }
  const readLatest = async () => {
    if (!base || !current()) return
    const attemptCurrent = captureAttempt?.() ?? (() => true)
    if (!attemptCurrent()) return
    setLatestError('')
    try {
      if (workspace.kind !== 'ready') return
      const latest = await fetchPublishedArtifact(base.artifact.id, undefined, undefined, workspace.value)
      if (current() && attemptCurrent()) setState({ kind: 'conflict', message: '최신 버전과 작성 중인 원고를 비교해 주세요. 원고는 자동으로 바뀌지 않습니다.', latest })
    } catch (error) {
      if (current() && attemptCurrent()) setLatestError(error instanceof Error ? error.message : '최신 버전을 읽지 못했습니다.')
    }
  }
  const field = (key: 'title' | 'summary' | 'content', value: string) => updateDraft({ [key]: value })
  return html`<section aria-label="아티팩트 편집" class="space-y-3 p-4 sm:p-6">
    <div class="flex flex-wrap items-center justify-between gap-3">
      <h2 class="m-0 text-lg font-semibold">${base ? `문서 편집 · v${base.artifact.revision} 기준` : '새 아티팩트'}</h2>
      <button type="button" onClick=${onCancel} disabled=${state.kind === 'saving'}>편집 닫기</button>
    </div>
    <label class="block text-sm">제목<input aria-label="문서 제목" class="mt-1 block w-full rounded border p-2 bg-[var(--color-bg-base)]"
      disabled=${!ready} value=${draft.title} onInput=${(event: Event) => field('title', (event.target as HTMLInputElement).value)} /></label>
    <label class="block text-sm">요약<input aria-label="문서 요약" class="mt-1 block w-full rounded border p-2 bg-[var(--color-bg-base)]"
      disabled=${!ready} value=${draft.summary} onInput=${(event: Event) => field('summary', (event.target as HTMLInputElement).value)} /></label>
    <label class="block text-sm">형식 <select aria-label="문서 형식" disabled=${!ready} value=${draft.format}
      onChange=${(event: Event) => updateDraft({ format: (event.target as HTMLSelectElement).value as ArtifactDraft['format'] })}>
      <option value="markdown">Markdown</option><option value="html">HTML</option></select></label>
    <label class="block text-sm">본문<textarea aria-label="문서 본문" spellcheck=${false}
      class="mt-1 block min-h-80 w-full resize-y rounded border p-3 font-mono text-sm bg-[var(--color-bg-base)]"
      disabled=${!ready} value=${draft.content} onInput=${(event: Event) => field('content', (event.target as HTMLTextAreaElement).value)} /></label>
    <div class="flex flex-wrap gap-4 text-sm">
      <button type="button" onClick=${save} disabled=${workspace.kind !== 'ready' || state.kind !== 'ready' || !draft.title.trim() || !draft.summary.trim() || !draft.content.trim()}>
        ${state.kind === 'saving' ? '저장 중…' : base ? '새 버전 저장' : '아티팩트 등록'}</button>
      <button type="button" onClick=${() => downloadArtifactDraft(draft)}>원고 다운로드</button>
    </div>
    ${state.kind === 'conflict' ? html`<div role="alert" class="space-y-3">
      <p>${state.message}</p><button type="button" onClick=${readLatest}>최신 버전과 비교</button>
      ${state.latest ? html`<div><h3>서버 최신 버전 · v${state.latest.artifact.revision} · ${state.latest.artifact.author}</h3>
        <pre class="max-h-80 overflow-auto whitespace-pre-wrap">${state.latest.content}</pre>
        <p>원고를 다운로드한 뒤 편집을 닫고 최신 버전에서 다시 시작해 주세요.</p></div>` : null}
    </div>` : state.kind === 'unconfirmed' ? html`<div role="alert"><p>${state.message}</p>
      <p>자동으로 다시 저장하지 않습니다. 원고를 다운로드하고 저장된 버전을 확인해 주세요.</p>
      ${state.publication ? html`<a href=${artifactHref(state.publication.artifact.id, state.publication.artifact.revision)}>응답받은 버전 확인</a>` : null}
    </div>` : state.kind === 'saved' ? html`<p role="status">${state.message ?? `v${state.publication.artifact.revision} 저장 후 내용을 다시 읽어 확인했습니다.`}</p>` : null}
    ${latestError ? html`<p role="alert">${latestError}</p>` : null}
    ${workspace.kind === 'loading' ? html`<p role="status">작업 공간을 확인하고 있습니다.</p>` : null}
    ${workspace.kind === 'error' ? html`<div role="alert"><p>${workspace.message}</p>
      <p>작업 공간을 확인하지 못해 저장할 수 없습니다. 원고를 다운로드하고 편집을 다시 열어 주세요.</p></div>` : null}
    ${state.kind === 'ready' && state.message ? html`<p role="alert">${state.message}</p>` : null}
  </section>`
}
