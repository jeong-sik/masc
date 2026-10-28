import { html } from 'htm/preact'
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from 'preact/hooks'
import { route, navigate } from '../../router'
import { ApiRequestError, currentStoredTokenRevision, getStoredToken } from '../../api/core'
import { storedTokenRevision } from '../../api/token-revision'
import { fetchPublishedArtifacts, fetchPublishedArtifact, fetchPublicArtifact, artifactHref, type ArtifactList, type ArtifactDocument, type ArtifactPublication } from '../../api/published-artifacts'
import { artifactExternalSharing, type ShareObservation } from '../../lib/artifact-external-sharing'
import { ExternalShareOutcomes } from './external-share-outcomes'
import { fetchArtifactChecks, resolveArtifactCheck, type ArtifactCheckList, type ArtifactCheckState } from '../../api/published-artifact-checks'
import { DEFAULT_PANEL_REFRESH_MS, setupVisibleAutoRefresh } from '../../lib/auto-refresh'
import { ArtifactReader } from './artifact-reader'
import { ArtifactPreview } from './artifact-preview'
import { ArtifactCheckControl, type ArtifactCheckOutcome } from './artifact-check-control'
import { executionWorkspaceAuthority } from '../../store'
import { ArtifactImport } from './artifact-import'
import { downloadArtifactDraft, type ArtifactDraftRetention, type ArtifactDraftSnapshot, type ArtifactPublicationOutcome } from './artifact-composer'

type Remote<T> = { key: object; kind: 'loaded'; data: T; receivedAt: number }
  | { key: object; kind: 'error'; message: string; data?: T }
const errorMessage = (error: unknown) => error instanceof ApiRequestError && error.status === 404
  ? '문서 또는 선택한 버전을 찾지 못했습니다.'
  : error instanceof Error ? error.message : '문서를 불러오지 못했습니다.'

function isToday(timestamp: string, now: Date): boolean {
  const date = new Date(timestamp)
  return date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth()
    && date.getDate() === now.getDate()
}

export function ArtifactsSurface() {
  const authRevision = storedTokenRevision.value
  const authority = executionWorkspaceAuthority.value
  const { artifact: selectedId, revision } = route.value.params
  const mounts = useRef(0)
  const [ownerEpoch, setOwnerEpoch] = useState(0)
  // The ordinal is only a component key. Authority is the existing SSOT object.
  const owner = useMemo(() => ({ mount: ++mounts.current, authRevision, authority, retired: false }), [authRevision, authority, ownerEpoch])
  useLayoutEffect(() => {
    const retire = () => {
      if (!owner.retired && (currentStoredTokenRevision() !== owner.authRevision
        || executionWorkspaceAuthority.peek() !== owner.authority)) {
        owner.retired = true
        setOwnerEpoch(epoch => epoch + 1)
      }
    }
    const unsubscribeWorkspace = executionWorkspaceAuthority.subscribe(retire)
    const unsubscribeCredential = storedTokenRevision.subscribe(retire)
    return () => { unsubscribeWorkspace(); unsubscribeCredential() }
  }, [owner])
  const [receipts, setReceipts] = useState<readonly { owner: typeof owner; outcome: ArtifactCheckOutcome }[]>([])
  const [publications, setPublications] = useState<readonly { owner: typeof owner; outcome: ArtifactPublicationOutcome }[]>([])
  const [drafts, setDrafts] = useState<readonly { owner: typeof owner; snapshot: ArtifactDraftSnapshot }[]>([])
  // Callbacks close over the original owner, never the replacement authority.
  const draftRetention: ArtifactDraftRetention = {
    remember: snapshot => setDrafts(previous => {
      const entry = { owner, snapshot }
      return previous.some(item => item.owner === owner && item.snapshot.identity === snapshot.identity)
        ? previous.map(item => item.owner === owner && item.snapshot.identity === snapshot.identity ? entry : item)
        : [...previous, entry]
    }),
    forget: identity => setDrafts(previous => previous.filter(item => item.owner !== owner || item.snapshot.identity !== identity)),
  }
  const retiredDrafts = drafts.filter(entry => entry.owner !== owner)
  const ownsSession = () => !owner.retired && currentStoredTokenRevision() === owner.authRevision
    && executionWorkspaceAuthority.peek() === owner.authority
  const current = () => owner.authority !== null && ownsSession()
  const publicSelection = selectedId && (authority === null || getStoredToken() === null)
  return html`<div>
    <${ExternalShareOutcomes} />
    ${retiredDrafts.length ? html`<section aria-label="이전 접근 상태의 원고" class="space-y-3 p-4">
      <h2>이전 접근 상태의 원고</h2>
      <p>접근 상태가 바뀌어 편집을 중단했습니다. 이 원고는 현재 권한으로 저장할 수 없습니다. 화면을 떠나기 전에 다운로드해 주세요.</p>
      ${retiredDrafts.map(({ owner: original, snapshot }) => html`<article key=${snapshot.identity}>
        <h3>${snapshot.value.title}</h3>
        <p>원래 작업 공간 ${original.authority?.workspaceRoot}${snapshot.base ? ` · ${snapshot.base.id} · v${snapshot.base.revision} 기준` : ' · 새 문서'}</p>
        <button type="button" onClick=${() => downloadArtifactDraft(snapshot.value)}>원고 다운로드</button>
        <button type="button" onClick=${() => {
          if (window.confirm('보관한 원고를 폐기할까요? 다운로드하지 않은 내용은 사라집니다.')) {
            setDrafts(previous => previous.filter(entry => entry.owner !== original || entry.snapshot.identity !== snapshot.identity))
          }
        }}>원고 폐기</button>
      </article>`)}
    </section>` : null}
    ${publications.length ? html`<section aria-label="문서 저장 요청 결과">
      ${publications.map(({ owner: original, outcome }, index) => html`<p key=${index}>
        ${outcome.title} · 원래 작업 공간 ${original.authority?.workspaceRoot}
        ${outcome.kind === 'published' ? html` · <a href=${artifactHref(outcome.publication.artifact.id, outcome.publication.artifact.revision)}>
          ${outcome.publication.artifact.id} · v${outcome.publication.artifact.revision}</a>
          · ${outcome.verified ? '저장 내용 확인됨' : '저장 응답 받음 · 내용 확인 필요'}`
          : ` · 적용 여부 미확인: ${outcome.detail}`}
        ${original !== owner ? ' · 이전 접근 상태의 요청 결과' : ''}
      </p>`)}
    </section>` : null}
    ${receipts.length ? html`<section aria-label="문서 확인 요청 결과">
      ${receipts.map(({ owner: original, outcome }, index) => html`<p key=${index}>
        ${outcome.artifact.title} · ${outcome.artifact.id} · v${outcome.artifact.revision}
        · SHA-256 ${outcome.artifact.body._blob.sha256}
        · 원래 작업 공간 ${original.authority?.workspaceRoot}
        · 요청: ${outcome.checked ? '확인' : '확인 해제'}
        · ${outcome.kind === 'received'
          ? `서버 응답: ${outcome.check.checked ? '확인' : '확인 해제'} · ${outcome.check.changed_by} · ${outcome.check.change_id}`
          : `적용 여부 미확인: ${outcome.detail}`}
        ${original !== owner ? ' · 이전 접근 상태의 요청 결과' : ''}
      </p>`)}
    </section>` : null}
    ${authority === null || publicSelection
      ? (retiredDrafts.length === 0 && selectedId
          ? html`<${SharedArtifactObservation} key=${`${owner.mount}:${selectedId}:${revision ?? ''}`}
              authRevision=${authRevision} selectedId=${selectedId} revision=${revision} isCurrent=${ownsSession} />`
          : html`<p role="status">${retiredDrafts.length ? '이전 원고를 처리한 뒤 문서를 읽습니다.' : '현재 작업 공간을 확인한 뒤 아티팩트를 읽습니다.'}</p>`)
      : html`<${ArtifactsObservation} key=${owner.mount} authRevision=${authRevision} isCurrent=${current}
          workspaceRoot=${authority.workspaceRoot} draftRetention=${draftRetention} allowReader=${retiredDrafts.length === 0}
          onPublication=${(outcome: ArtifactPublicationOutcome) => setPublications(previous => {
            const index = outcome.kind === 'published' ? previous.findIndex(entry => entry.owner === owner
              && entry.outcome.kind === 'published'
              && entry.outcome.publication.artifact.id === outcome.publication.artifact.id
              && entry.outcome.publication.artifact.revision === outcome.publication.artifact.revision) : -1
            return index < 0 ? [...previous, { owner, outcome }]
              : previous.map((entry, position) => position === index ? { owner, outcome } : entry)
          })}
          onMutation=${(outcome: ArtifactCheckOutcome) => setReceipts(previous => [...previous, { owner, outcome }])} />`}
  </div>`
}

const noopDraftRetention: ArtifactDraftRetention = { remember: () => {}, forget: () => {} }
type ObservedDocument =
  | { kind: 'operator'; document: ArtifactDocument; shareObservation: ShareObservation }
  | { kind: 'public'; document: ArtifactDocument }
type DocumentRemote = Remote<ObservedDocument> | { key: object; kind: 'public-loading' }

const selectedArtifact = (id: string, revision: string | undefined) => {
  const selected = route.peek()
  return selected.tab === 'workspace' && selected.params.section === 'artifacts'
    && selected.params.artifact === id && selected.params.revision === revision
}

function SharedArtifactReader({ doc, revision, authRevision, isCurrent }: {
  doc: ArtifactDocument; revision: string | undefined; authRevision: number; isCurrent: () => boolean
}) {
  return html`<${ArtifactReader} doc=${doc} fixedRevision=${revision !== undefined} readOnly=${true}
    draftRetention=${noopDraftRetention} workspaceRoot=""
    checkState=${{ kind: 'unknown', message: '외부 공유 열람' }} authRevision=${authRevision}
    isCurrent=${isCurrent} onMutation=${() => {}} onCheckChanged=${() => {}}
    onPublication=${() => {}} onPublished=${() => {}}
    onClose=${() => navigate('workspace', { section: 'artifacts' })} />`
}

function SharedArtifactObservation({ authRevision, selectedId, revision, isCurrent }: {
  authRevision: number; selectedId: string; revision: string | undefined; isCurrent: () => boolean
}) {
  const [document, setDocument] = useState<Remote<ArtifactDocument> | null>(null)
  const [visitEpoch, setVisitEpoch] = useState(0)
  const documentKey = useMemo(() => ({}), [selectedId, revision, visitEpoch])
  const visit = useMemo(() => ({ retired: false }), [documentKey])
  const active = useRef(true)
  const current = () => active.current && !visit.retired && isCurrent() && selectedArtifact(selectedId, revision)
  useEffect(() => () => { active.current = false }, [])
  useEffect(() => {
    if (!current()) return
    const controller = new AbortController()
    const retire = () => {
      if (!current()) {
        if (!visit.retired) {
          visit.retired = true
          if (active.current) setVisitEpoch(epoch => epoch + 1)
        }
        controller.abort()
      }
    }
    const unsubscribeRoute = route.subscribe(retire)
    const unsubscribeWorkspace = executionWorkspaceAuthority.subscribe(retire)
    const unsubscribeCredential = storedTokenRevision.subscribe(retire)
    void fetchPublicArtifact(selectedId, revision, controller.signal).then(data => {
      if (!controller.signal.aborted && current()) setDocument({ key: documentKey, kind: 'loaded', data, receivedAt: Date.now() })
    }, error => {
      if (!controller.signal.aborted && current()) setDocument({ key: documentKey, kind: 'error', message: errorMessage(error) })
    })
    return () => { controller.abort(); unsubscribeRoute(); unsubscribeWorkspace(); unsubscribeCredential() }
  }, [authRevision, selectedId, revision, documentKey])
  const doc = document?.key === documentKey ? document : null
  if (doc === null) return html`<p role="status">문서를 불러오고 있습니다.</p>`
  if (!doc.data) return html`<p role="alert">${doc.kind === 'error' ? doc.message : '문서를 읽지 못했습니다.'}</p>`
  return html`<${SharedArtifactReader} doc=${doc.data} revision=${revision} authRevision=${authRevision} isCurrent=${current} />`
}

function ArtifactsObservation({ authRevision, workspaceRoot, draftRetention, allowReader, isCurrent, onMutation, onPublication }: {
  authRevision: number; isCurrent: () => boolean; onMutation: (outcome: ArtifactCheckOutcome) => void
  onPublication: (outcome: ArtifactPublicationOutcome) => void
  workspaceRoot: string
  draftRetention: ArtifactDraftRetention
  allowReader: boolean
}) {
  const { artifact: selectedId, revision } = route.value.params
  const [refresh, setRefresh] = useState(0)
  const [query, setQuery] = useState('')
  const [format, setFormat] = useState<'all' | 'markdown' | 'html'>('all')
  const [todayOnly, setTodayOnly] = useState(false)
  const [uncheckedOnly, setUncheckedOnly] = useState(false)
  const [previewId, setPreviewId] = useState<string | null>(null)
  const [importing, setImporting] = useState(false)
  const [catalog, setCatalog] = useState<Remote<ArtifactList> | null>(null)
  const [document, setDocument] = useState<DocumentRemote | null>(null)
  const documentRef = useRef<DocumentRemote | null>(null)
  documentRef.current = document
  const [checks, setChecks] = useState<Remote<ArtifactCheckList> | null>(null)
  const catalogKey = useMemo(() => ({}), [])
  const selections = useRef(0)
  const [visitEpoch, setVisitEpoch] = useState(0)
  const documentKey = useMemo(() => ({ visit: ++selections.current }), [selectedId, revision])
  // A synchronously retired visit fences continuations even if the route
  // returns before render; keep the document key so an open draft survives.
  const visit = useMemo(() => ({ retired: false }), [documentKey, visitEpoch])
  const activeDocumentKey = useRef(documentKey)
  activeDocumentKey.current = documentKey
  const readerAllowed = useRef(allowReader)
  readerAllowed.current = allowReader
  const shareActivity = selectedId ? artifactExternalSharing.activity(selectedId, workspaceRoot) : 'ready'
  const shareReread = useRef<ShareObservation | null>(null)
  const active = useRef(true)
  const current = () => active.current && isCurrent()
  const currentDocument = () => current() && readerAllowed.current && !visit.retired && activeDocumentKey.current === documentKey
    && selectedId !== undefined && selectedArtifact(selectedId, revision)
  useEffect(() => () => { active.current = false }, [])

  useEffect(() => setupVisibleAutoRefresh(() => setRefresh(n => n + 1), DEFAULT_PANEL_REFRESH_MS), [])
  useEffect(() => {
    const controller = new AbortController()
    void fetchPublishedArtifacts(controller.signal).then(data => {
      if (!controller.signal.aborted && current()) setCatalog({ key: catalogKey, kind: 'loaded', data, receivedAt: Date.now() })
    }, error => {
      if (!controller.signal.aborted && current()) setCatalog({ key: catalogKey, kind: 'error', message: errorMessage(error) })
    })
    return () => controller.abort()
  }, [authRevision, catalogKey, refresh])
  useEffect(() => {
    const controller = new AbortController()
    setChecks(null)
    void fetchArtifactChecks(controller.signal).then(data => {
      if (!controller.signal.aborted && current()) setChecks({ key: catalogKey, kind: 'loaded', data, receivedAt: Date.now() })
    }, error => {
      if (!controller.signal.aborted && current()) setChecks({ key: catalogKey, kind: 'error', message: errorMessage(error) })
    })
    return () => controller.abort()
  }, [authRevision, catalogKey, refresh])
  useEffect(() => {
    if (!selectedId || !currentDocument()) return
    const controller = new AbortController()
    const retire = () => {
      if (!currentDocument()) {
        if (!visit.retired) {
          visit.retired = true
          if (active.current) setVisitEpoch(epoch => epoch + 1)
        }
        controller.abort()
      }
    }
    const unsubscribeRoute = route.subscribe(retire)
    const unsubscribeWorkspace = executionWorkspaceAuthority.subscribe(retire)
    const unsubscribeCredential = storedTokenRevision.subscribe(retire)
    const publish = (next: DocumentRemote) => {
      if (!controller.signal.aborted && currentDocument()) { documentRef.current = next; setDocument(next) }
    }
    const shareObservation = artifactExternalSharing.observe(selectedId, workspaceRoot)
    void fetchPublishedArtifact(selectedId, revision, controller.signal).then(document => {
      publish({ key: documentKey, kind: 'loaded', data: { kind: 'operator', document, shareObservation }, receivedAt: Date.now() })
    }, error => {
      if (controller.signal.aborted || !currentDocument()) return
      const previous = documentRef.current
      const retained = previous?.key === documentKey && previous.kind !== 'public-loading'
        && previous.data?.kind === 'operator' ? previous.data : undefined
      if (retained || !(error instanceof ApiRequestError && (error.status === 401 || error.status === 403))) {
        // Keep the same visit's editor and draft mounted after a failed refresh.
        publish({ key: documentKey, kind: 'error', message: errorMessage(error), data: retained })
        return
      }
      publish({ key: documentKey, kind: 'public-loading' })
      void fetchPublicArtifact(selectedId, revision, controller.signal).then(document => {
        publish({ key: documentKey, kind: 'loaded', data: { kind: 'public', document }, receivedAt: Date.now() })
      }, publicError => {
        publish({ key: documentKey, kind: 'error', message: errorMessage(publicError) })
      })
    })
    return () => { controller.abort(); unsubscribeRoute(); unsubscribeWorkspace(); unsubscribeCredential() }
  }, [authRevision, selectedId, revision, documentKey, visit, refresh, allowReader])

  const list = catalog?.key === catalogKey ? catalog : null
  const doc = document?.key === documentKey ? document : null
  useEffect(() => {
    const observation = doc && doc.kind !== 'public-loading' && doc.data?.kind === 'operator'
      ? doc.data.shareObservation : undefined
    if (selectedId && shareActivity === 'ready' && observation?.id === selectedId
      && !artifactExternalSharing.admits(observation) && shareReread.current !== observation && current()) {
      shareReread.current = observation
      setRefresh(n => n + 1)
    }
  }, [selectedId, shareActivity, doc, documentKey])
  const checkInventory = checks?.key === catalogKey ? checks : null
  const checkState = (artifact: ArtifactDocument['artifact']): ArtifactCheckState =>
    checkInventory?.kind === 'loaded' ? resolveArtifactCheck(artifact, checkInventory.data)
      : { kind: 'unknown', message: checkInventory?.kind === 'error' ? checkInventory.message : '확인 상태 조회 중' }
  const checkChanged = () => {
    if (!current()) return
    setChecks(null)
    setRefresh(n => n + 1)
  }
  const published = (publication: ArtifactPublication) => {
    if (!current()) return
    setImporting(false)
    setRefresh(n => n + 1)
    navigate('workspace', { section: 'artifacts', artifact: publication.artifact.id, revision: String(publication.artifact.revision) })
  }
  const search = query.trim().toLocaleLowerCase()
  const now = new Date()
  const todayCount = list?.kind === 'loaded' ? list.data.artifacts.filter(a => isToday(a.created_at, now)).length : null
  const canFilterChecks = list?.kind === 'loaded' && list.data.diagnostics.length === 0
    && checkInventory?.kind === 'loaded' && checkInventory.data.diagnostics.length === 0
    && list.data.artifacts.every(artifact => checkState(artifact).kind === 'known')
  const todayChecks = list?.kind === 'loaded' && list.data.diagnostics.length === 0
    ? list.data.artifacts.filter(a => isToday(a.created_at, now)).map(checkState) : null
  const uncheckedToday = todayChecks !== null && canFilterChecks
    ? todayChecks.filter(state => state.kind === 'known' && !state.check?.checked).length : null
  const artifacts = list?.kind === 'loaded' ? list.data.artifacts.filter(a => {
    const state = checkState(a)
    return `${a.title}\n${a.summary}\n${a.author}`.toLocaleLowerCase().includes(search)
      && (format === 'all' || a.format === format)
      && (!todayOnly || isToday(a.created_at, now))
      && (!uncheckedOnly || (canFilterChecks && state.kind === 'known' && !state.check?.checked))
  }) : []
  return html`
    <section class="space-y-4" aria-label="아티팩트 보관함">
      <header class="flex flex-wrap items-center justify-between gap-3">
        <div><h1 class="m-0 text-xl font-semibold">아티팩트</h1>
          <p class="mt-1 text-sm text-[var(--color-fg-secondary)]">Keeper가 작성한 보고서와 결과물을 다시 읽어보세요.</p></div>
        <div class="flex gap-4"><button type="button" disabled=${!allowReader}
          onClick=${() => { if (readerAllowed.current) setImporting(true) }}>파일 가져오기</button>
          <button type="button" onClick=${() => setRefresh(n => n + 1)}>새로고침</button></div>
      </header>
      ${importing ? html`<${ArtifactImport} draftRetention=${draftRetention} workspaceRoot=${workspaceRoot} isCurrent=${current} onMutation=${onPublication} onSaved=${published}
        onCancel=${() => setImporting(false)} />` : null}
      <div class="min-w-0 space-y-4">
        <aside class="min-w-0 space-y-3" aria-label="아티팩트 목록">
          <input type="search" aria-label="아티팩트 검색" placeholder="제목, 요약, 작성자 검색"
            class="w-full max-w-lg rounded border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-2 text-sm"
            value=${query} onInput=${(event: Event) => setQuery((event.target as HTMLInputElement).value)} />
          <div class="flex flex-wrap items-center gap-3 text-sm">
            <label>형식 ${' '}<select aria-label="아티팩트 형식" value=${format}
              onChange=${(event: Event) => setFormat((event.target as HTMLSelectElement).value as typeof format)}>
              <option value="all">모든 형식</option><option value="markdown">Markdown 문서</option><option value="html">HTML 웹 페이지</option>
            </select></label>
            <button type="button" aria-pressed=${todayOnly} onClick=${() => setTodayOnly(value => !value)}>오늘 게시·수정${todayCount === null ? '' : ` ${todayCount}개`}</button>
            <span>오늘 미확인 ${uncheckedToday === null ? '조회 필요' : `${uncheckedToday}개`}</span>
            <button type="button" aria-pressed=${uncheckedOnly} disabled=${!uncheckedOnly && !canFilterChecks}
              onClick=${() => setUncheckedOnly(value => !value)}>미확인만</button>
            ${list?.kind === 'loaded' ? html`<span class="text-xs text-[var(--color-fg-muted)]">
              목록 조회 <time dateTime=${new Date(list.receivedAt).toISOString()}>${new Date(list.receivedAt).toLocaleTimeString()}</time>
              · 전체 ${list.data.artifacts.length}개${list.data.diagnostics.length ? ' · 일부 조회 실패' : ''}
            </span>` : null}
          </div>
          ${checkInventory?.kind === 'error' ? html`<p role="alert" class="text-xs">확인 상태 조회 실패: ${checkInventory.message}</p>`
            : checkInventory?.kind === 'loaded' && checkInventory.data.diagnostics.length
              ? html`<p role="alert" class="text-xs">일부 확인 기록을 읽지 못했습니다. ${checkInventory.data.diagnostics.map(d => `${d.file}: ${d.error}`).join(' · ')}</p>` : null}
          ${list === null ? html`<p role="status">목록을 불러오고 있습니다.</p>`
            : list.kind === 'error' ? html`<p role="alert">${list.message}</p>`
            : html`
              ${list.data.diagnostics.length ? html`<p role="alert" class="text-xs">일부 문서를 읽지 못했습니다. ${list.data.diagnostics.map(d => `${d.id}: ${d.error}`).join(' · ')}</p>` : null}
              ${artifacts.length === 0 ? html`<p role="status" class="text-sm text-[var(--color-fg-secondary)]">${uncheckedOnly && uncheckedToday === null ? '확인 상태를 읽지 못해 미확인 목록을 판단할 수 없습니다.' : search || format !== 'all' || todayOnly || uncheckedOnly ? '조건에 맞는 아티팩트가 없습니다.' : '아직 게시된 아티팩트가 없습니다. Keeper가 보고서를 게시하면 여기에 표시됩니다.'}</p>` : null}
              <ul class="m-0 grid list-none gap-4 p-0 xl:grid-cols-2">
                ${artifacts.map(a => html`<li key=${a.id}>
                  <article class="h-full overflow-hidden rounded-lg border border-[var(--color-border-default)] bg-[var(--color-bg-surface)]">
                  <button type="button" aria-current=${a.id === selectedId ? 'true' : undefined}
                    class="w-full p-4 text-left hover:bg-[var(--color-bg-hover)]"
                    onClick=${() => navigate('workspace', { section: 'artifacts', artifact: a.id })}>
                    <span class="flex flex-wrap items-center gap-2 text-xs">
                      <span class=${`rounded border px-2 py-1 ${a.format === 'html' ? 'border-violet-400/40 bg-violet-400/10 text-violet-300' : 'border-sky-400/40 bg-sky-400/10 text-sky-300'}`}>${a.format === 'html' ? 'HTML · 웹 페이지' : 'Markdown · 문서'}</span>
                      <span class="text-[var(--color-fg-muted)]">v${a.revision}</span>
                      ${isToday(a.created_at, now) ? html`<span class="font-semibold text-[var(--color-fg-default)]">오늘</span>` : null}
                    </span>
                    <strong class="mt-1 block break-words">${a.title}</strong>
                    <span class="mt-1 block break-words text-sm text-[var(--color-fg-secondary)]">${a.summary}</span>
                    <span class="mt-2 block text-xs text-[var(--color-fg-muted)]">${a.author} · ${new Date(a.created_at).toLocaleString()}</span>
                  </button>
                  <div class="border-t border-[var(--color-border-default)] px-4 py-2">
                    <${ArtifactCheckControl} key=${JSON.stringify([authRevision,a.id,a.revision,a.body._blob.sha256])}
                      artifact=${a} state=${checkState(a)} authRevision=${authRevision} isCurrent=${current} onMutation=${onMutation} onChanged=${checkChanged} />
                  </div>
                  ${a.format === 'html' ? html`
                    <div class="border-t border-[var(--color-border-default)] px-4 py-2 text-sm">
                      <button type="button" aria-expanded=${previewId === a.id}
                        onClick=${() => setPreviewId(value => value === a.id ? null : a.id)}>
                        ${previewId === a.id ? '미리보기 접기' : 'HTML 미리보기'}
                      </button>
                    </div>
                    ${previewId === a.id ? html`<${ArtifactPreview} key=${JSON.stringify([authRevision, a.id, a.revision, a.body._blob.sha256])} artifact=${a} authRevision=${authRevision} isCurrent=${current} />` : null}
                  ` : null}
                  </article>
                </li>`)}
              </ul>`}
        </aside>
        ${!allowReader ? html`<p role="status">이전 원고를 처리한 뒤 문서를 읽습니다.</p>`
          : !selectedId ? html`<div class="rounded-lg border border-dashed border-[var(--color-border-default)] p-8 text-sm text-[var(--color-fg-secondary)]">목록에서 문서를 선택하면 본문이 열립니다.</div>`
          : doc === null ? html`<p role="status">문서를 불러오고 있습니다.</p>`
          : doc.kind === 'public-loading' ? html`<p role="status">외부 공유 문서를 확인하고 있습니다.</p>`
          : !doc.data ? html`<p role="alert">${doc.kind === 'error' ? doc.message : '문서를 읽지 못했습니다.'}</p>`
          : doc.data.kind === 'public' ? html`<${SharedArtifactReader} key=${`public-${documentKey.visit}`}
              doc=${doc.data.document} revision=${revision} authRevision=${authRevision}
              isCurrent=${currentDocument} />`
          : html`<${ArtifactReader} key=${documentKey.visit} doc=${doc.data.document} fixedRevision=${revision !== undefined}
              draftRetention=${draftRetention} workspaceRoot=${workspaceRoot}
              shareObservation=${doc.data.shareObservation}
              readError=${doc.kind === 'error' ? doc.message : undefined}
              checkState=${checkState(doc.data.document.artifact)} authRevision=${authRevision} isCurrent=${currentDocument} onMutation=${onMutation} onCheckChanged=${checkChanged}
              onPublication=${onPublication} onPublished=${published}
              onClose=${() => navigate('workspace', { section: 'artifacts' })} />`}
      </div>
    </section>
  `
}
