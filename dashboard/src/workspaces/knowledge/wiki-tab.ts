/**
 * `3 Knowledge > Librarian Wiki` Tab (`wiki-tab.ts` — BRAND NEW!)
 *
 * - `MasterDetail`:
 *   - Clustered page index (`GET /api/v1/wiki`, `V2Envelope`) by tag & source.
 *   - Live search (`GET /api/v1/wiki/search?q=...`, `V2Envelope`).
 *   - Lint findings panel (`GET /api/v1/wiki/lint`, `V2Envelope`).
 *   - Wiki Log timeline (`GET /api/v1/wiki/log`, `V2Envelope`).
 *   - Safe sanitized Markdown preview (`marked` + `dompurify`).
 *   - CAS Markdown Editor (`PUT /api/v1/wiki/:slug` sending `expected_sha256` & `expected_revision`)
 *     with explicit **`409 conflict_cas` reload-and-diff recovery**!
 */

import { html } from 'htm/preact'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { markViewSynced } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { apiGetV2, apiMutateV2 } from '../../core/transport'
import { KeeperBadge } from '../../components/keeper-badge'
import { MasterDetail, VirtualList } from '../../components/primitives'
import {
  WIKI_SOURCES,
  computeMarkdownLineDiff,
  formatRelativeTime,
  type WikiIndexData,
  type WikiLintData,
  type WikiLogData,
  type WikiPageData,
  type WikiPageSummary,
  type WikiPutRespData,
  type WikiSearchData,
  type WikiSource,
  type WorkspaceViewProps,
} from './types'

type WikiLeftView = 'pages' | 'lint' | 'log'

interface CasConflictState {
  readonly serverPage: WikiPageData
  readonly localBody: string
  readonly localTitle: string
  readonly localSummary: string
  readonly message: string
}

export function WikiTab(props: WorkspaceViewProps) {
  const [leftView, setLeftView] = useState<WikiLeftView>('pages')
  const [wikiIndex, setWikiIndex] = useState<WikiIndexData | null>(null)
  const lintObs = resourceCache.observe<WikiLintData>('kn:wiki:lint').value
  const logObs = resourceCache.observe<WikiLogData>('kn:wiki:log').value
  const lintData = lintObs.kind === 'value' ? lintObs.data : null
  const logData = logObs.kind === 'value' ? logObs.data : null
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)

  // Filters & Live Search
  const [tagFilter, setTagFilter] = useState('')
  const [sourceFilter, setSourceFilter] = useState('')
  const [sort, setSort] = useState<'updated' | 'title' | 'rank'>('updated')
  const [searchQuery, setSearchQuery] = useState('')
  const [searchResult, setSearchResult] = useState<WikiSearchData | null>(null)
  const [searching, setSearching] = useState(false)

  // Active Page & Editor / CAS Recovery
  const [selectedSlug, setSelectedSlug] = useState<string | null>(props.entityId ?? null)
  const [pageDetail, setPageDetail] = useState<WikiPageData | null>(null)
  const [pageLoading, setPageLoading] = useState(false)
  const [pageError, setPageError] = useState<string | null>(null)
  const pageAbortRef = useRef<AbortController | null>(null)

  const [editing, setEditing] = useState(false)
  const [creatingNew, setCreatingNew] = useState(false)
  const [editSlug, setEditSlug] = useState('')
  const [editTitle, setEditTitle] = useState('')
  const [editSummary, setEditSummary] = useState('')
  const [editSource, setEditSource] = useState<WikiSource>('observation')
  const [editTags, setEditTags] = useState('')
  const [editBody, setEditBody] = useState('')
  const [editNote, setEditNote] = useState('')
  const [expectedSha, setExpectedSha] = useState<string | null>(null)
  const [expectedRev, setExpectedRev] = useState<number | null>(null)
  const [saving, setSaving] = useState(false)
  const [saveFeedback, setSaveFeedback] = useState<{ kind: 'ok' | 'err'; message: string } | null>(null)
  const [casConflict, setCasConflict] = useState<CasConflictState | null>(null)
  const submitSaveRef = useRef<() => Promise<void>>(async () => {})

  const loadIndex = useCallback(async (reason: 'mount' | 'manual' = 'mount') => {
    setLoading(true)
    setLoadError(null)
    const params = new URLSearchParams({ sort })
    if (tagFilter) params.set('tag', tagFilter)
    if (sourceFilter) params.set('source', sourceFilter)
    const obs = await resourceCache.fetch<WikiIndexData>(
      `kn:wiki:index:${params.toString()}`,
      (signal) => apiGetV2<WikiIndexData>(`/api/v1/wiki?${params.toString()}`, { signal }),
      { ttlMs: 12_000, topics: ['wiki', 'wiki_updated'], reason },
    )
    setLoading(false)
    if (obs.kind === 'value') {
      setWikiIndex(obs.data)
      markViewSynced()
      setSelectedSlug((prev) => {
        if (props.entityId && obs.data.pages.some((p) => p.slug === props.entityId)) return props.entityId
        if (prev && obs.data.pages.some((p) => p.slug === prev)) return prev
        return obs.data.pages[0]?.slug ?? null
      })
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [sort, tagFilter, sourceFilter, props.entityId])

  useEffect(() => {
    void loadIndex('mount')
  }, [loadIndex])

  const loadLint = useCallback((reason: 'mount' | 'manual') => {
    void resourceCache.fetch(
      'kn:wiki:lint',
      (signal) => apiGetV2<WikiLintData>('/api/v1/wiki/lint', { signal }),
      { reason, topics: ['wiki', 'wiki_updated'] },
    )
  }, [])
  const loadLog = useCallback((reason: 'mount' | 'manual') => {
    void resourceCache.fetch(
      'kn:wiki:log',
      (signal) => apiGetV2<WikiLogData>('/api/v1/wiki/log?limit=100', { signal }),
      { reason, topics: ['wiki', 'wiki_updated'] },
    )
  }, [])

  useEffect(() => {
    if (leftView === 'lint') loadLint('mount')
    if (leftView === 'log') loadLog('mount')
  }, [leftView, loadLint, loadLog])

  // Live search via GET /api/v1/wiki/search?q=
  const runSearch = useCallback(async (qRaw: string) => {
    const q = qRaw.trim()
    if (!q) {
      setSearchResult(null)
      return
    }
    setSearching(true)
    const res = await apiGetV2<WikiSearchData>(`/api/v1/wiki/search?q=${encodeURIComponent(q)}&limit=30`)
    setSearching(false)
    if (res.ok) setSearchResult(res.value)
  }, [])

  const loadPage = useCallback(async (slug: string, signal?: AbortSignal) => {
    setPageLoading(true)
    setPageError(null)
    const res = await apiGetV2<WikiPageData>(`/api/v1/wiki/${encodeURIComponent(slug)}`, { signal })
    if (signal?.aborted) return null
    setPageLoading(false)
    if (!res.ok) {
      setPageError(res.error.message)
      return null
    }
    setPageDetail(res.value)
    return res.value
  }, [])

  useEffect(() => {
    pageAbortRef.current?.abort()
    if (!selectedSlug || creatingNew) return
    setEditing(false)
    setPageDetail(null)
    setCasConflict(null)
    setSaveFeedback(null)
    const ctrl = new AbortController()
    pageAbortRef.current = ctrl
    void loadPage(selectedSlug, ctrl.signal)
    return () => {
      ctrl.abort()
    }
  }, [selectedSlug, creatingNew, loadPage])

  const startEdit = (page: WikiPageData) => {
    setCreatingNew(false)
    setEditing(true)
    setCasConflict(null)
    setSaveFeedback(null)
    setEditSlug(page.slug)
    setEditTitle(page.frontmatter.title)
    setEditSummary(page.frontmatter.summary)
    setEditSource(page.frontmatter.source)
    setEditTags(page.frontmatter.tags.join(', '))
    setEditBody(page.body_markdown)
    setEditNote('')
    setExpectedSha(page.sha256)
    setExpectedRev(page.frontmatter.revision)
  }

  const startNewPage = () => {
    setCreatingNew(true)
    setEditing(true)
    setCasConflict(null)
    setSaveFeedback(null)
    setEditSlug('')
    setEditTitle('')
    setEditSummary('')
    setEditSource('observation')
    setEditTags('')
    setEditBody('')
    setEditNote('create page')
    setExpectedSha(null)
    setExpectedRev(null)
  }

  const submitSave = async (overrideCas?: { sha256: string; revision: number }) => {
    const targetSlug = editSlug.trim()
    if (!targetSlug || !editTitle.trim()) {
      setSaveFeedback({ kind: 'err', message: 'Slug와 페이지 제목을 모두 입력하세요.' })
      return
    }
    setSaving(true)
    setSaveFeedback(null)
    const tags = editTags
      .split(',')
      .map((t) => t.trim())
      .filter(Boolean)
    const body: Record<string, unknown> = {
      title: editTitle.trim(),
      summary: editSummary.trim(),
      source: editSource,
      tags,
      body: editBody,
      note: editNote.trim() || 'dashboard edit',
    }
    const useSha = overrideCas?.sha256 ?? expectedSha
    const useRev = overrideCas?.revision ?? expectedRev
    if (!creatingNew) {
      if (useSha) body.expected_sha256 = useSha
      if (useRev !== null) body.expected_revision = useRev
    }

    const res = await apiMutateV2<WikiPutRespData>(
      'PUT',
      `/api/v1/wiki/${encodeURIComponent(targetSlug)}`,
      body,
    )
    setSaving(false)

    if (!res.ok) {
      if (res.error.kind === 'conflict_cas' || res.error.status === 409 || res.error.code === 'conflict_cas') {
        // Explicit 409 conflict_cas reload-and-diff recovery!
        const latestRes = await apiGetV2<WikiPageData>(`/api/v1/wiki/${encodeURIComponent(targetSlug)}`)
        if (latestRes.ok) {
          setCasConflict({
            serverPage: latestRes.value,
            localBody: editBody,
            localTitle: editTitle,
            localSummary: editSummary,
            message: res.error.message || '409 conflict_cas: 다른 작성자가 페이지를 먼저 수정했습니다.',
          })
        } else {
          setSaveFeedback({
            kind: 'err',
            message: `409 CAS 충돌이 발생했으나 최신 페이지를 다시 읽지 못했습니다: ${latestRes.error.message}`,
          })
        }
        return
      }
      setSaveFeedback({ kind: 'err', message: `저장 실패: ${res.error.message}` })
      return
    }

    setCasConflict(null)
    setCreatingNew(false)
    setEditing(false)
    setSelectedSlug(res.value.slug)
    setSaveFeedback({
      kind: 'ok',
      message: `${res.value.slug} (rev ${res.value.revision}) ${res.value.action === 'created' ? '생성' : '저장'} 완료`,
    })
    resourceCache.invalidateTopic('wiki')
    await loadIndex('manual')
    pageAbortRef.current?.abort()
    const ctrl = new AbortController()
    pageAbortRef.current = ctrl
    await loadPage(res.value.slug, ctrl.signal)
  }

  submitSaveRef.current = () => submitSave()

  useEffect(() => {
    if (!editing) return
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.isComposing || e.keyCode === 229) return
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 's') {
        e.preventDefault()
        if (!saving) void submitSaveRef.current()
      }
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [editing, saving])

  const conflictDiff = useMemo(() => {
    if (!casConflict) return []
    return computeMarkdownLineDiff(casConflict.serverPage.body_markdown, casConflict.localBody)
  }, [casConflict])

  const displayedPages = wikiIndex?.pages ?? []

  const masterPane = html`
    <div class="kn-pane-col">
      <div class="kn-pane-head">
        <div class="kn-chips" role="tablist" aria-label="Wiki 보기">
          <button type="button" role="tab" class="kn-chip" aria-selected=${leftView === 'pages'} aria-pressed=${leftView === 'pages'} onClick=${() => setLeftView('pages')}>
            Pages <span class="kn-chip-count">${wikiIndex?.pages_total ?? 0}</span>
          </button>
          <button type="button" role="tab" class="kn-chip" aria-selected=${leftView === 'lint'} aria-pressed=${leftView === 'lint'} onClick=${() => setLeftView('lint')}>
            Lint <span class="kn-chip-count">${wikiIndex?.lint.total_findings ?? 0}</span>
          </button>
          <button type="button" role="tab" class="kn-chip" aria-selected=${leftView === 'log'} aria-pressed=${leftView === 'log'} onClick=${() => setLeftView('log')}>
            Log
          </button>
        </div>
        <div class="kn-actions">
          <button type="button" class="btn-primary" onClick=${startNewPage}>+ 새 페이지</button>
          <button type="button" class="btn-ghost" onClick=${() => void loadIndex('manual')}>새로고침</button>
        </div>
      </div>

      ${leftView === 'pages' && html`
        <div class="kn-filter-bar">
          <form
            class="kn-search-row"
            onSubmit=${(e: Event) => {
              e.preventDefault()
              void runSearch(searchQuery)
            }}
          >
            <input
              type="search"
              class="kn-input kn-search-input"
              placeholder="Wiki 전문 검색 (GET /api/v1/wiki/search)…"
              value=${searchQuery}
              onInput=${(e: Event) => {
                const val = (e.target as HTMLInputElement).value
                setSearchQuery(val)
                if (!val.trim()) setSearchResult(null)
              }}
              aria-label="Wiki 검색"
            />
            <button type="submit" class="btn-ghost" disabled=${searching}>
              ${searching ? '검색 중…' : '검색'}
            </button>
          </form>

          <div class="kn-toolbar">
            <select
              class="kn-select"
              value=${sourceFilter}
              onChange=${(e: Event) => setSourceFilter((e.target as HTMLSelectElement).value)}
              aria-label="출처 필터"
            >
              <option value="">전체 출처</option>
              ${WIKI_SOURCES.map((s) => html`<option key=${s} value=${s}>${s}</option>`)}
            </select>
            <select
              class="kn-select"
              value=${sort}
              onChange=${(e: Event) => setSort((e.target as HTMLSelectElement).value as 'updated' | 'title' | 'rank')}
              aria-label="페이지 정렬"
            >
              <option value="updated">최근 수정순</option>
              <option value="title">제목순</option>
              <option value="rank">연결 순위순</option>
            </select>
          </div>

          ${wikiIndex && wikiIndex.tags.length > 0 && html`
            <div class="kn-chips" aria-label="태그 클러스터">
              <button type="button" class="kn-chip" aria-pressed=${tagFilter === ''} onClick=${() => setTagFilter('')}>
                전체 태그
              </button>
              ${wikiIndex.tags.slice(0, 12).map((t) => html`
                <button
                  key=${t.tag}
                  type="button"
                  class="kn-chip"
                  aria-pressed=${tagFilter === t.tag}
                  onClick=${() => setTagFilter(tagFilter === t.tag ? '' : t.tag)}
                >
                  #${t.tag} <span class="kn-chip-count">${t.count}</span>
                </button>
              `)}
            </div>
          `}
        </div>

        ${loadError && html`<div class="kn-notice kn-notice--err kn-inset" role="alert">${loadError}</div>`}

        ${searchResult
          ? html`
              <div class="kn-search-results">
                <div class="kn-row-meta">
                  <span>검색 결과: <strong>${searchResult.count}</strong>건 ("${searchResult.query}")</span>
                  <button type="button" class="btn-ghost kn-btn-compact" onClick=${() => { setSearchQuery(''); setSearchResult(null) }}>
                    검색 닫기
                  </button>
                </div>
                ${searchResult.results.map((r) => html`
                  <button
                    key=${r.slug}
                    type="button"
                    class="kn-row-btn"
                    data-selected=${selectedSlug === r.slug ? 'true' : 'false'}
                    onClick=${() => {
                      setCreatingNew(false)
                      setSelectedSlug(r.slug)
                    }}
                  >
                    <div class="kn-row-top">
                      <span class="kn-row-title">${r.title}</span>
                      <span class="kn-badge kn-badge--info">${r.match_tier}</span>
                    </div>
                    <div class="kn-row-meta">
                      <span class="mono">${r.slug}</span>
                      <span>rev ${r.revision}</span>
                    </div>
                    ${r.snippets[0] && html`
                      <div class="kn-sub-line">
                        L${r.snippets[0].line}: ${r.snippets[0].text}
                      </div>
                    `}
                  </button>
                `)}
              </div>
            `
          : loading && !wikiIndex
            ? html`<div class="kn-detail-pad"><span class="dtable-absent">Wiki 인덱스 불러오는 중…</span></div>`
            : html`
                <${VirtualList}
                  items=${displayedPages}
                  estimateSize=${76}
                  height="100%"
                  ariaLabel="Wiki 페이지 목록"
                  getItemKey=${(p: WikiPageSummary) => p.slug}
                  empty=${html`<div class="kn-detail-pad"><span class="dtable-absent">등록된 Wiki 페이지가 없습니다.</span></div>`}
                  renderItem=${(p: WikiPageSummary) => html`
                    <button
                      type="button"
                      class="kn-row-btn"
                      data-selected=${!creatingNew && selectedSlug === p.slug ? 'true' : 'false'}
                      onClick=${() => {
                        setCreatingNew(false)
                        setSelectedSlug(p.slug)
                      }}
                    >
                      <div class="kn-row-top">
                        <span class="kn-row-title">${p.title}</span>
                        <span class="kn-badge">${p.source}</span>
                      </div>
                      <div class="kn-row-meta">
                        <span class="mono">${p.slug}</span>
                        <span class="tnum">rev ${p.revision}</span>
                        <span class="tnum">← ${p.backlink_count}</span>
                        <span>${formatRelativeTime(p.updated)}</span>
                      </div>
                    </button>
                  `}
                />
              `}
      `}

      ${leftView === 'lint' && html`
        <div class="kn-detail-pad kn-scroll-pad">
          <div class="kn-section-head">
            <h3 class="kn-section-title">Wiki Lint Findings</h3>
            <button type="button" class="btn-ghost" onClick=${() => loadLint('manual')}>다시 검사</button>
          </div>
          ${(lintObs.kind === 'failed' || lintObs.kind === 'absent' || lintObs.kind === 'unreported')
            ? html`<div class="kn-notice kn-notice--err" role="alert">Lint 보고서 조회 실패: ${lintObs.kind === 'failed' ? lintObs.error.message : lintObs.reason ?? '응답을 확인할 수 없습니다.'}</div>`
            : !lintData
            ? html`<span class="dtable-absent">Lint 보고서 불러오는 중…</span>`
            : html`
                <div class="kn-chips">
                  ${Object.entries(lintData.counts).map(([k, v]) => html`
                    <span key=${k} class=${`kn-badge ${v > 0 ? 'kn-badge--warn' : 'kn-badge--ok'}`}>
                      ${k}: ${v}
                    </span>
                  `)}
                </div>
                ${lintData.duplicate_title_candidates.length > 0 && html`
                  <div class="kn-notice kn-notice--warn">
                    중복 제목 후보 ${lintData.duplicate_title_candidates.length}쌍 감지됨
                  </div>
                `}
                ${lintData.findings.length === 0
                  ? html`<div class="kn-notice kn-notice--ok">Lint 경고가 없습니다 (0).</div>`
                  : lintData.findings.map((f, idx) => html`
                      <button
                        key=${`${f.kind}-${f.subject}-${idx}`}
                        type="button"
                        class="kn-row-btn kn-card-row"
                        onClick=${() => {
                          const target = f.page ?? f.subject
                          if (target) {
                            setCreatingNew(false)
                            setSelectedSlug(target)
                          }
                        }}
                      >
                        <div class="kn-row-top">
                          <span class="kn-badge kn-badge--warn">${f.kind}</span>
                          <span class="mono kn-sub-id">${f.page ?? f.subject}</span>
                        </div>
                        <div class="kn-body-sm">
                          ${f.reason ?? f.target ?? f.subject} ${f.line ? `(L${f.line})` : ''}
                        </div>
                      </button>
                    `)}
              `}
        </div>
      `}

      ${leftView === 'log' && html`
        <div class="kn-detail-pad kn-scroll-pad">
          <div class="kn-section-head">
            <h3 class="kn-section-title">Wiki Revision Log</h3>
            <button type="button" class="btn-ghost" onClick=${() => loadLog('manual')}>새로고침</button>
          </div>
          ${(logObs.kind === 'failed' || logObs.kind === 'absent' || logObs.kind === 'unreported')
            ? html`<div class="kn-notice kn-notice--err" role="alert">Wiki 로그 조회 실패: ${logObs.kind === 'failed' ? logObs.error.message : logObs.reason ?? '응답을 확인할 수 없습니다.'}</div>`
            : !logData
            ? html`<span class="dtable-absent">로그 불러오는 중…</span>`
            : logData.entries.length === 0
              ? html`<span class="dtable-absent">기록된 Wiki 로그가 없습니다.</span>`
              : logData.entries.map((entry) => html`
                  <button
                    key=${entry.idx}
                    type="button"
                    class="kn-row-btn kn-card-row"
                    onClick=${() => {
                      setCreatingNew(false)
                      setSelectedSlug(entry.page)
                    }}
                  >
                    <div class="kn-row-top">
                      <span class="mono">${entry.page}</span>
                      <span class="kn-badge kn-badge--info">${entry.action} · r${entry.revision}</span>
                    </div>
                    <div class="kn-row-meta">
                      ${entry.author && html`<${KeeperBadge} id=${entry.author} size="sm" />`}
                      <span>${formatRelativeTime(entry.written_at_unix)}</span>
                      ${entry.note && html`<span>${entry.note}</span>`}
                    </div>
                  </button>
                `)}
        </div>
      `}
    </div>
  `

  const detailPane = editing
    ? html`
        <div class="kn-detail-pad">
          <div class="kn-section-head">
            <div>
              <h2 class="kn-heading-tight">
                ${creatingNew ? '새 Wiki 페이지 작성' : `편집: ${editSlug}`}
              </h2>
              ${!creatingNew && expectedSha && html`
                <div class="mono kn-sub-id">
                  CAS Lock: rev ${expectedRev ?? '없음'} · sha256 ${expectedSha.slice(0, 12)}…
                </div>
              `}
            </div>
            <div class="kn-actions">
              <button type="button" class="btn-primary" disabled=${saving} onClick=${() => void submitSave()}>
                ${saving ? '저장 중…' : 'CAS 저장 (PUT)'}
              </button>
              <button type="button" class="btn-ghost" onClick=${() => { setEditing(false); setCreatingNew(false); setCasConflict(null) }}>
                취소
              </button>
            </div>
          </div>

          ${saveFeedback && html`
            <div class=${`kn-notice kn-notice--${saveFeedback.kind}`} role="status">${saveFeedback.message}</div>
          `}

          ${casConflict && html`
            <section class="kn-section kn-conflict-box" role="alert" aria-label="409 CAS 충돌 복구">
              <div class="kn-section-head">
                <strong class="kn-conflict-title">409 conflict_cas — 동시 편집 충돌 감지</strong>
                <span class="mono kn-sub-id">
                  서버 최신 rev ${casConflict.serverPage.frontmatter.revision} · ${casConflict.serverPage.sha256.slice(0, 10)}…
                </span>
              </div>
              <div class="kn-body-sm">${casConflict.message}</div>
              <div class="kn-sub-id">
                Diff (- 서버 최신본 / + 내 로컬 초안):
              </div>
              <pre class="kn-diff-box">${conflictDiff.map((chunk, idx) => html`
                <span
                  key=${idx}
                  class=${chunk.kind === 'added' ? 'kn-diff-added' : chunk.kind === 'removed' ? 'kn-diff-removed' : 'kn-diff-equal'}
                >${chunk.kind === 'added' ? '+ ' : chunk.kind === 'removed' ? '- ' : '  '}${chunk.text}</span>
              `)}</pre>
              <div class="kn-actions">
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => {
                    startEdit(casConflict.serverPage)
                    setSaveFeedback({ kind: 'ok', message: '서버 최신 리비전으로 에디터를 다시 불러왔습니다.' })
                  }}
                >
                  서버 최신본으로 다시 불러오기 (Reload)
                </button>
                <button
                  type="button"
                  class="kn-btn-warn"
                  disabled=${saving}
                  onClick=${() => {
                    setExpectedSha(casConflict.serverPage.sha256)
                    setExpectedRev(casConflict.serverPage.frontmatter.revision)
                    void submitSave({
                      sha256: casConflict.serverPage.sha256,
                      revision: casConflict.serverPage.frontmatter.revision,
                    })
                  }}
                >
                  최신 리비전 기준으로 내 수정본 저장 (Rebase & Retry)
                </button>
              </div>
            </section>
          `}

          <div class="kn-grid-auto">
            <div class="kn-field">
              <label for="wiki-slug" class="kn-field-label">Slug</label>
              <input
                id="wiki-slug"
                class="kn-input mono"
                disabled=${!creatingNew}
                value=${editSlug}
                onInput=${(e: Event) => setEditSlug((e.target as HTMLInputElement).value)}
                placeholder="예: architecture-notes"
              />
            </div>
            <div class="kn-field">
              <label for="wiki-title" class="kn-field-label">제목</label>
              <input
                id="wiki-title"
                class="kn-input"
                value=${editTitle}
                onInput=${(e: Event) => setEditTitle((e.target as HTMLInputElement).value)}
              />
            </div>
            <div class="kn-field">
              <label for="wiki-source" class="kn-field-label">출처 (source)</label>
              <select
                id="wiki-source"
                class="kn-select"
                value=${editSource}
                onChange=${(e: Event) => setEditSource((e.target as HTMLSelectElement).value as WikiSource)}
              >
                ${WIKI_SOURCES.map((s) => html`<option key=${s} value=${s}>${s}</option>`)}
              </select>
            </div>
          </div>

          <input
            type="text"
            class="kn-input"
            placeholder="요약 (summary)"
            value=${editSummary}
            onInput=${(e: Event) => setEditSummary((e.target as HTMLInputElement).value)}
            aria-label="페이지 요약"
          />
          <div class="kn-grid-2">
            <input
              type="text"
              class="kn-input"
              placeholder="태그 (쉼표 구분)"
              value=${editTags}
              onInput=${(e: Event) => setEditTags((e.target as HTMLInputElement).value)}
              aria-label="태그"
            />
            <input
              type="text"
              class="kn-input"
              placeholder="변경 메모 (commit note)"
              value=${editNote}
              onInput=${(e: Event) => setEditNote((e.target as HTMLInputElement).value)}
              aria-label="변경 메모"
            />
          </div>

          <textarea
            class="kn-textarea kn-textarea--editor"
            value=${editBody}
            onInput=${(e: Event) => setEditBody((e.target as HTMLTextAreaElement).value)}
            onKeyDown=${(e: KeyboardEvent) => {
              if (e.isComposing || e.keyCode === 229) return
              if ((e.metaKey || e.ctrlKey) && e.key === 'Enter' && !saving) {
                e.preventDefault()
                void submitSave()
              }
            }}
            aria-label="Markdown 본문 편집기"
          />
        </div>
      `
    : pageDetail
      ? html`
          <div class="kn-detail-pad">
            ${saveFeedback && html`<div class=${`kn-notice kn-notice--${saveFeedback.kind}`} role="status">${saveFeedback.message}</div>`}
            <div class="kn-section-head">
              <div class="kn-min-w-0">
                <div class="kn-row-meta">
                  <span class="mono">${pageDetail.slug}</span>
                  <span class="kn-badge">${pageDetail.frontmatter.source}</span>
                  <span class="mono tnum">rev ${pageDetail.frontmatter.revision}</span>
                  <span class="mono">sha256:${pageDetail.sha256.slice(0, 12)}</span>
                </div>
                <h2 class="kn-heading">${pageDetail.frontmatter.title}</h2>
                ${pageDetail.frontmatter.summary && html`
                  <${MarkdownContent} class="kn-subcopy" text=${pageDetail.frontmatter.summary} />
                `}
              </div>
              <div class="kn-actions">
                <button type="button" class="btn-primary" onClick=${() => startEdit(pageDetail)}>
                  CAS 편집
                </button>
                <button
                  type="button"
                  class="btn-ghost"
                  onClick=${() => props.onInspect({
                    title: `Wiki: ${pageDetail.frontmatter.title}`,
                    subtitle: `${pageDetail.slug} · rev ${pageDetail.frontmatter.revision}`,
                    kind: 'wiki',
                    data: pageDetail,
                  })}
                >
                  메타데이터
                </button>
              </div>
            </div>

            <div class="kn-row-meta">
              <${KeeperBadge} id=${pageDetail.frontmatter.author} size="sm" />
              <span>수정: ${formatRelativeTime(pageDetail.frontmatter.updated)}</span>
              ${pageDetail.frontmatter.tags.map((tag) => html`<span key=${tag} class="kn-badge">#${tag}</span>`)}
            </div>

            ${pageDetail.lint_findings.length > 0 && html`
              <div class="kn-notice kn-notice--warn">
                이 페이지에 Lint 경고 ${pageDetail.lint_findings.length}건이 있습니다:
                ${pageDetail.lint_findings.map((f) => f.kind).join(', ')}
              </div>
            `}

            <article class="kn-md-panel">
              <${MarkdownContent} text=${pageDetail.body_markdown} document />
            </article>

            <div class="kn-grid-links">
              <section class="kn-section">
                <h3 class="kn-section-title">Backlinks (${pageDetail.backlinks.length})</h3>
                ${pageDetail.backlinks.length === 0
                  ? html`<span class="dtable-absent">없음</span>`
                  : html`
                      <div class="kn-chips">
                        ${pageDetail.backlinks.map((slug) => html`
                          <button key=${slug} type="button" class="kn-chip mono" onClick=${() => setSelectedSlug(slug)}>
                            ${slug}
                          </button>
                        `)}
                      </div>
                    `}
              </section>
              <section class="kn-section">
                <h3 class="kn-section-title">Outgoing Links (${pageDetail.outgoing_links.length})</h3>
                ${pageDetail.outgoing_links.length === 0
                  ? html`<span class="dtable-absent">없음</span>`
                  : html`
                      <div class="kn-chips">
                        ${pageDetail.outgoing_links.map((link, idx) => html`
                          <button
                            key=${`${link.target}-${idx}`}
                            type="button"
                            class="kn-chip"
                            onClick=${() => {
                              if (link.kind === 'page' && link.exists) setSelectedSlug(link.target)
                            }}
                          >
                            ${link.text || link.target}
                            ${link.exists === false && html`<span class="kn-badge kn-badge--err">broken</span>`}
                          </button>
                        `)}
                      </div>
                    `}
              </section>
            </div>
          </div>
        `
      : pageLoading
        ? html`<div class="kn-detail-pad"><span class="dtable-absent">Wiki 페이지 불러오는 중…</span></div>`
        : pageError
          ? html`<div class="kn-detail-pad"><div class="kn-notice kn-notice--err" role="alert">${pageError}</div></div>`
          : null

  return html`
    <${MasterDetail}
      master=${masterPane}
      detail=${detailPane}
      hasSelection=${editing || pageDetail !== null || pageLoading || pageError !== null}
      selectionKey=${creatingNew ? '__new__' : selectedSlug}
      masterLabel="Wiki 인덱스"
      detailLabel="Wiki 본문 및 CAS 편집기"
      emptyDetail=${html`<div class="kn-detail-pad"><span class="dtable-absent">Wiki 페이지를 선택하거나 "+ 새 페이지"를 눌러 문서를 작성하세요.</span></div>`}
    />
  `
}
