import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import { route, navigate } from '../../router'
import { ApiRequestError, currentStoredTokenRevision } from '../../api/core'
import { storedTokenRevision } from '../../api/token-revision'
import { fetchPublishedArtifacts, fetchPublishedArtifact, type ArtifactList, type ArtifactDocument } from '../../api/published-artifacts'
import { fetchArtifactChecks, resolveArtifactCheck, type ArtifactCheckList, type ArtifactCheckState } from '../../api/published-artifact-checks'
import { DEFAULT_PANEL_REFRESH_MS, setupVisibleAutoRefresh } from '../../lib/auto-refresh'
import { ArtifactReader } from './artifact-reader'
import { ArtifactPreview } from './artifact-preview'
import { ArtifactCheckControl } from './artifact-check-control'

type Remote<T> = { key: string; kind: 'loaded'; data: T; receivedAt: number }
  | { key: string; kind: 'error'; message: string }
const errorMessage = (error: unknown) => error instanceof ApiRequestError && error.status === 404
  ? '문서 또는 선택한 버전을 찾지 못했습니다.'
  : error instanceof Error ? error.message : '문서를 불러오지 못했습니다.'

function isToday(timestamp: string, now: Date): boolean {
  const date = new Date(timestamp)
  return date.getFullYear() === now.getFullYear() && date.getMonth() === now.getMonth()
    && date.getDate() === now.getDate()
}

export function ArtifactsSurface() {
  const { artifact: selectedId, revision } = route.value.params
  const authRevision = storedTokenRevision.value
  const [refresh, setRefresh] = useState(0)
  const [query, setQuery] = useState('')
  const [format, setFormat] = useState<'all' | 'markdown' | 'html'>('all')
  const [todayOnly, setTodayOnly] = useState(false)
  const [uncheckedOnly, setUncheckedOnly] = useState(false)
  const [previewId, setPreviewId] = useState<string | null>(null)
  const [catalog, setCatalog] = useState<Remote<ArtifactList> | null>(null)
  const [document, setDocument] = useState<Remote<ArtifactDocument> | null>(null)
  const [checks, setChecks] = useState<Remote<ArtifactCheckList> | null>(null)
  const catalogKey = String(authRevision)
  const documentKey = JSON.stringify([authRevision, selectedId, revision])

  useEffect(() => setupVisibleAutoRefresh(() => setRefresh(n => n + 1), DEFAULT_PANEL_REFRESH_MS), [])
  useEffect(() => {
    const controller = new AbortController()
    void fetchPublishedArtifacts(controller.signal).then(data => {
      if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) setCatalog({ key: catalogKey, kind: 'loaded', data, receivedAt: Date.now() })
    }, error => {
      if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) setCatalog({ key: catalogKey, kind: 'error', message: errorMessage(error) })
    })
    return () => controller.abort()
  }, [authRevision, catalogKey, refresh])
  useEffect(() => {
    const controller = new AbortController()
    setChecks(null)
    void fetchArtifactChecks(controller.signal).then(data => {
      if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) setChecks({ key: catalogKey, kind: 'loaded', data, receivedAt: Date.now() })
    }, error => {
      if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) setChecks({ key: catalogKey, kind: 'error', message: errorMessage(error) })
    })
    return () => controller.abort()
  }, [authRevision, catalogKey, refresh])
  useEffect(() => {
    if (!selectedId) return
    const controller = new AbortController()
    void fetchPublishedArtifact(selectedId, revision, controller.signal).then(data => {
      if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) setDocument({ key: documentKey, kind: 'loaded', data, receivedAt: Date.now() })
    }, error => {
      if (!controller.signal.aborted && currentStoredTokenRevision() === authRevision) setDocument({ key: documentKey, kind: 'error', message: errorMessage(error) })
    })
    return () => controller.abort()
  }, [authRevision, selectedId, revision, documentKey, refresh])

  const list = catalog?.key === catalogKey ? catalog : null
  const doc = document?.key === documentKey ? document : null
  const checkInventory = checks?.key === catalogKey ? checks : null
  const checkState = (artifact: ArtifactDocument['artifact']): ArtifactCheckState =>
    checkInventory?.kind === 'loaded' ? resolveArtifactCheck(artifact, checkInventory.data)
      : { kind: 'unknown', message: checkInventory?.kind === 'error' ? checkInventory.message : '확인 상태 조회 중' }
  const checkChanged = () => {
    if (currentStoredTokenRevision() !== authRevision) return
    setChecks(null)
    setRefresh(n => n + 1)
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
        <button type="button" onClick=${() => setRefresh(n => n + 1)}>새로고침</button>
      </header>
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
                    <${ArtifactCheckControl} key=${JSON.stringify([authRevision,a.id,a.revision,a.body.sha256])}
                      artifact=${a} state=${checkState(a)} authRevision=${authRevision} onChanged=${checkChanged} />
                  </div>
                  ${a.format === 'html' ? html`
                    <div class="border-t border-[var(--color-border-default)] px-4 py-2 text-sm">
                      <button type="button" aria-expanded=${previewId === a.id}
                        onClick=${() => setPreviewId(value => value === a.id ? null : a.id)}>
                        ${previewId === a.id ? '미리보기 접기' : 'HTML 미리보기'}
                      </button>
                    </div>
                    ${previewId === a.id ? html`<${ArtifactPreview} key=${JSON.stringify([authRevision, a.id, a.revision])} artifact=${a} authRevision=${authRevision} />` : null}
                  ` : null}
                  </article>
                </li>`)}
              </ul>`}
        </aside>
        ${!selectedId ? html`<div class="rounded-lg border border-dashed border-[var(--color-border-default)] p-8 text-sm text-[var(--color-fg-secondary)]">목록에서 문서를 선택하면 본문이 열립니다.</div>`
          : doc === null ? html`<p role="status">문서를 불러오고 있습니다.</p>`
          : doc.kind === 'error' ? html`<p role="alert">${doc.message}</p>`
          : html`<${ArtifactReader} key=${selectedId} doc=${doc.data} fixedRevision=${revision !== undefined}
              checkState=${checkState(doc.data.artifact)} authRevision=${authRevision} onCheckChanged=${checkChanged}
              onClose=${() => navigate('workspace', { section: 'artifacts' })} />`}
      </div>
    </section>
  `
}
