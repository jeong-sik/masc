/**
 * `3 Knowledge > Lean Artifacts` Tab (`artifacts-tab.ts`)
 *
 * - `MasterDetail` + `VirtualList`: Published HTML / Markdown artifact list (`GET /api/v1/published-artifacts`).
 * - Safe sandboxed HTML iframe preview (`sandbox=""`) with authenticated `/api/v1/media/<sha256>`
 *   data-URI hydration (bounded & aborted cleanly) OR DOMPurify-sanitized Markdown render.
 * - Copy content, Copy SHA-256, Download `.html`/`.md`, revision switching — ZERO Office/HWP/PDF/Yjs bloat!
 */

import { html } from 'htm/preact'
import { copyToClipboard } from '../../components/common/copyable-code'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { authSession, canUseSingleUserTokenAdmin, currentSessionEpoch, isEpochCurrent, sessionEpoch } from '../../core/auth'
import { markViewSnapshot } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { apiGet } from '../../core/transport'
import { WORKSPACE_MEDIA_PREFIX } from '../../lib/keeper-media'
import { ok } from '../../lib/result'
import {
  hydrateSandboxedHtmlMedia,
  SANDBOX_HTML_MAX_MEDIA_ITEMS,
  type SandboxedHtmlMediaHydrationResult,
} from '../../lib/workspace-media-cache'
import { KeeperBadge } from '../../components/keeper-badge'
import { MasterDetail } from '../../components/primitives/master-detail'
import { PopoverMenu } from '../../components/primitives/popover-menu'
import { RefreshButton } from '../../components/primitives/refresh-button'
import { VirtualList } from '../../components/primitives/virtual-list'
import { pushShellToast } from '../../shell/shell-state'
import {
  asNonEmptyString,
  asSafeInt,
  asString,
  decodePublishedArtifactItem,
  formatBytes,
  formatRelativeTime,
  isRecord,
  type ArtifactDocumentData,
  type PublishedArtifactItem,
  type WorkspaceViewProps,
} from './types'

export interface ArtifactListBundle {
  readonly artifacts: readonly PublishedArtifactItem[]
  readonly diagnostics: readonly { readonly id: string; readonly error: string }[]
}

export async function fetchPublishedArtifactsList(signal: AbortSignal) {
  const res = await apiGet<unknown>('/api/v1/published-artifacts', { signal })
  if (!res.ok) return res
  const artifacts: PublishedArtifactItem[] = []
  const diagnostics: { id: string; error: string }[] = []
  if (isRecord(res.value)) {
    if (Array.isArray(res.value.artifacts)) {
      for (const row of res.value.artifacts) {
        const dec = decodePublishedArtifactItem(row)
        if (dec) artifacts.push(dec)
      }
    }
    if (Array.isArray(res.value.diagnostics)) {
      for (const d of res.value.diagnostics) {
        if (!isRecord(d)) continue
        const id = asNonEmptyString(d.id)
        const errMsg = asNonEmptyString(d.error)
        if (id && errMsg) diagnostics.push({ id, error: errMsg })
      }
    }
  }
  return ok<ArtifactListBundle>({ artifacts, diagnostics })
}

type HtmlHydrationState =
  | { readonly key: string; readonly kind: 'ready'; readonly result: SandboxedHtmlMediaHydrationResult }
  | { readonly key: string; readonly kind: 'error'; readonly message: string }

export function ArtifactsTab(props: WorkspaceViewProps) {
  const session = authSession.value
  const epoch = sessionEpoch.value
  const isSingleUser = session.kind === 'single_user_local'
  const canListArtifacts = canUseSingleUserTokenAdmin(session)
  const [bundle, setBundle] = useState<ArtifactListBundle>({ artifacts: [], diagnostics: [] })
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [formatFilter, setFormatFilter] = useState<'all' | 'html' | 'markdown'>('all')
  const [query, setQuery] = useState('')

  const [selectedId, setSelectedId] = useState<string | null>(props.entityId ?? null)
  const [selectedRevision, setSelectedRevision] = useState<number | null>(null)
  const [doc, setDoc] = useState<ArtifactDocumentData | null>(null)
  const [docError, setDocError] = useState<string | null>(null)
  const [htmlHydration, setHtmlHydration] = useState<HtmlHydrationState | null>(null)
  // A selected artifact with no document and no error is one being read: from
  // the first render, before the effect that reads it has run.
  const docLoading = selectedId !== null && doc === null && docError === null
  const docAbortRef = useRef<AbortController | null>(null)
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
      docAbortRef.current?.abort()
    }
  }, [])

  useEffect(() => {
    setSelectedRevision(null)
  }, [props.entityId])

  const loadList = useCallback(async (reason: 'mount' | 'manual' = 'mount') => {
    const curSession = authSession.peek()
    if (!canUseSingleUserTokenAdmin(curSession)) {
      setBundle({ artifacts: [], diagnostics: [] })
      if (curSession.kind !== 'single_user_local') {
        setSelectedId(null)
        setDoc(null)
      }
      setLoading(false)
      setLoadError(null)
      return
    }
    const startEpoch = currentSessionEpoch()
    setLoading(true)
    setLoadError(null)
    const obs = await resourceCache.fetch<ArtifactListBundle>(
      'kn:artifacts:list',
      fetchPublishedArtifactsList,
      { ttlMs: 15_000, topics: ['artifacts'], reason },
    )
    if (!mountedRef.current || !isEpochCurrent(startEpoch)) return
    setLoading(false)
    if (obs.kind === 'value') {
      setBundle(obs.data)
      markViewSnapshot()
      setSelectedId((prev) => {
        if (props.entityId && obs.data.artifacts.some((a) => a.id === props.entityId)) return props.entityId
        if (prev && obs.data.artifacts.some((a) => a.id === prev)) return prev
        return obs.data.artifacts[0]?.id ?? null
      })
    } else if (obs.kind === 'failed') {
      setLoadError(obs.error.message)
    }
  }, [props.entityId])

  useEffect(() => {
    void loadList('mount')
  }, [loadList, isSingleUser, canListArtifacts, epoch])

  const loadDocument = useCallback(async (id: string, revision: number | null, signal?: AbortSignal) => {
    if (authSession.peek().kind !== 'single_user_local') return
    setDocError(null)
    const revQuery = revision !== null ? `?revision=${revision}` : ''
    const res = await apiGet<unknown>(`/api/v1/published-artifacts/${encodeURIComponent(id)}${revQuery}`, { signal })
    if (signal?.aborted) return
    if (!res.ok) {
      setDocError(res.error.message)
      return
    }
    if (!isRecord(res.value)) {
      setDocError('아티팩트 문서 형식이 올바르지 않습니다.')
      return
    }
    const artifact = decodePublishedArtifactItem(res.value.artifact)
    if (!artifact) {
      setDocError('아티팩트 메타데이터를 해석하지 못했습니다.')
      return
    }
    const content = asString(res.value.content, '')
    const revisions: ArtifactDocumentData['revisions'][number][] = []
    if (Array.isArray(res.value.revisions)) {
      for (const r of res.value.revisions) {
        if (!isRecord(r)) continue
        const revNum = asSafeInt(r.revision)
        if (revNum === null) continue
        const bodyObj = isRecord(r.body) ? r.body : null
        const blobObj = bodyObj && isRecord(bodyObj._blob) ? bodyObj._blob : bodyObj
        revisions.push({
          revision: revNum,
          title: asString(r.title, artifact.title),
          createdAt: asString(r.created_at, ''),
          sha256: (blobObj ? asString(blobObj.sha256, '') : '') || asString(r.sha256, ''),
        })
      }
    }
    if (signal?.aborted) return
    setDoc({ artifact, content, revisions })
  }, [])

  useEffect(() => {
    docAbortRef.current?.abort()
    setDoc(null)
    setHtmlHydration(null)
    if (!selectedId) return
    const ctrl = new AbortController()
    docAbortRef.current = ctrl
    void loadDocument(selectedId, selectedRevision, ctrl.signal)
    return () => {
      ctrl.abort()
    }
  }, [selectedId, selectedRevision, epoch, loadDocument])

  const htmlDocKey = doc && doc.artifact.format === 'html'
    ? `${epoch}:${doc.artifact.id}:${doc.artifact.revision}:${doc.artifact.sha256}:${doc.content.length}`
    : null
  const needsHtmlMediaHydration = doc !== null
    && doc.artifact.format === 'html'
    && doc.content.includes(WORKSPACE_MEDIA_PREFIX)

  useEffect(() => {
    if (!doc || !htmlDocKey || !needsHtmlMediaHydration) {
      setHtmlHydration(null)
      return undefined
    }
    const controller = new AbortController()
    void hydrateSandboxedHtmlMedia(doc.content, {
      epoch,
      signal: controller.signal,
    }).then((res) => {
      if (controller.signal.aborted || !mountedRef.current || !isEpochCurrent(epoch)) return
      if (res.ok) {
        setHtmlHydration({ key: htmlDocKey, kind: 'ready', result: res.value })
      } else if (res.error.kind !== 'aborted') {
        setHtmlHydration({
          key: htmlDocKey,
          kind: 'error',
          message: '아티팩트 내부 이미지를 인라인으로 불러오지 못했습니다.',
        })
      }
    })
    return () => {
      controller.abort()
    }
  }, [doc, epoch, htmlDocKey, needsHtmlMediaHydration])

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    return bundle.artifacts.filter((a) => {
      if (formatFilter !== 'all' && a.format !== formatFilter) return false
      if (q && !a.title.toLowerCase().includes(q) && !a.summary.toLowerCase().includes(q) && !a.id.toLowerCase().includes(q)) {
        return false
      }
      return true
    })
  }, [bundle.artifacts, formatFilter, query])

  const copyText = async (text: string, label: string) => {
    const copied = await copyToClipboard(text)
    if (!mountedRef.current) return
    if (copied) {
      pushShellToast(`${label} 복사됨`, 'success')
    } else {
      pushShellToast('클립보드 복사를 지원하지 않는 환경입니다.', 'warning')
    }
  }

  const downloadArtifact = (current: ArtifactDocumentData) => {
    if (typeof document === 'undefined' || typeof URL === 'undefined' || typeof URL.createObjectURL !== 'function') return
    const ext = current.artifact.format === 'html' ? 'html' : 'md'
    const mime = current.artifact.format === 'html' ? 'text/html;charset=utf-8' : 'text/markdown;charset=utf-8'
    const blob = new Blob([current.content], { type: mime })
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = `${current.artifact.id}-r${current.artifact.revision}.${ext}`
    a.click()
    URL.revokeObjectURL(url)
  }

  const activeHtmlHydration = htmlDocKey && htmlHydration?.key === htmlDocKey ? htmlHydration : null

  const renderHtmlPreview = (current: ArtifactDocumentData) => {
    if (needsHtmlMediaHydration && activeHtmlHydration === null) {
      return html`
        <div class="kn-notice kn-notice--info" role="status" data-testid="artifact-media-hydrating">
          아티팩트 이미지 불러오는 중…
        </div>
      `
    }
    const srcDoc = activeHtmlHydration?.kind === 'ready'
      ? activeHtmlHydration.result.html
      : current.content
    const warningParts: string[] = []
    if (activeHtmlHydration?.kind === 'ready') {
      if (activeHtmlHydration.result.failedCount > 0) {
        warningParts.push(`이미지 ${activeHtmlHydration.result.failedCount}건을 불러오지 못했습니다.`)
      }
      if (activeHtmlHydration.result.skippedCount > 0) {
        warningParts.push(`인라인 한도(최대 ${SANDBOX_HTML_MAX_MEDIA_ITEMS}건 / 32 MiB)로 ${activeHtmlHydration.result.skippedCount}건 생략됨.`)
      }
    } else if (activeHtmlHydration?.kind === 'error') {
      warningParts.push(activeHtmlHydration.message)
    }
    return html`
      ${warningParts.length > 0 && html`
        <div class="kn-notice kn-notice--warn" role="status" data-testid="artifact-media-warning">
          ${warningParts.join(' ')}
        </div>
      `}
      <iframe
        class="kn-artifact-frame"
        sandbox=""
        srcDoc=${srcDoc}
        title=${`Sandboxed HTML Artifact: ${current.artifact.title}`}
      />
    `
  }

  const masterPane = html`
    <div class="kn-pane-col">
      <div class="kn-pane-head">
        <h2 class="kn-pane-title">Artifacts <span class="kn-chip-count">(${filtered.length})</span></h2>
        <${RefreshButton} onRefresh=${() => loadList('manual')} />
      </div>

      <div class="kn-filter-bar">
        <div class="kn-chips" role="group" aria-label="아티팩트 형식 필터">
          <button type="button" class="kn-chip" aria-pressed=${formatFilter === 'all'} onClick=${() => setFormatFilter('all')}>
            All <span class="kn-chip-count">${bundle.artifacts.length}</span>
          </button>
          <button type="button" class="kn-chip" aria-pressed=${formatFilter === 'html'} onClick=${() => setFormatFilter('html')}>
            HTML
          </button>
          <button type="button" class="kn-chip" aria-pressed=${formatFilter === 'markdown'} onClick=${() => setFormatFilter('markdown')}>
            Markdown
          </button>
        </div>
        <input
          type="search"
          class="kn-input"
          placeholder="아티팩트 제목, 요약, ID 검색…"
          value=${query}
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          aria-label="아티팩트 검색"
        />
      </div>

      ${!isSingleUser && html`
        <div class="kn-notice kn-notice--info kn-inset" data-testid="artifacts-mode-notice" role="status">
          발행된 아티팩트 조회는 싱글유저 로컬 세션에서 지원됩니다.
        </div>
      `}
      ${isSingleUser && !canListArtifacts && html`
        <div class="kn-notice kn-notice--info kn-inset" data-testid="artifacts-admin-locked" role="status">
          아티팩트 목록 조회(<code>/api/v1/published-artifacts</code>)는 토큰 기반 관리자 권한이 필요합니다.
        </div>
      `}
      ${loadError && html`<div class="kn-notice kn-notice--err kn-inset" role="alert">${loadError}</div>`}
      ${bundle.diagnostics.length > 0 && html`
        <div class="kn-notice kn-notice--warn kn-inset">
          읽기 진단 경고 ${bundle.diagnostics.length}건
        </div>
      `}

      ${loading && bundle.artifacts.length === 0
        ? html`<div class="kn-detail-pad"><span class="dtable-absent">아티팩트 불러오는 중…</span></div>`
        : html`
            <${VirtualList}
              items=${filtered}
              estimateSize=${76}
              height="100%"
              ariaLabel="발행된 아티팩트 목록"
              getItemKey=${(a: PublishedArtifactItem) => a.id}
              empty=${html`<div class="kn-detail-pad"><span class="dtable-absent">발행된 HTML/Markdown 아티팩트가 없습니다.</span></div>`}
              renderItem=${(a: PublishedArtifactItem) => html`
                <button
                  type="button"
                  class="kn-row-btn"
                  data-selected=${selectedId === a.id ? 'true' : 'false'}
                  onClick=${() => {
                    setSelectedId(a.id)
                    setSelectedRevision(null)
                  }}
                >
                  <div class="kn-row-top">
                    <span class="kn-row-title">${a.title}</span>
                    <span class=${`kn-badge ${a.format === 'html' ? 'kn-badge--info' : 'kn-badge--ok'}`}>
                      ${a.format.toUpperCase()}
                    </span>
                  </div>
                  <div class="kn-row-meta">
                    <${KeeperBadge} id=${a.author} size="sm" />
                    <span class="mono tnum">r${a.revision}</span>
                    <span class="tnum">${formatBytes(a.bytes)}</span>
                    <span>${formatRelativeTime(a.createdAt)}</span>
                  </div>
                </button>
              `}
            />
          `}
    </div>
  `

  const detailPane = doc
    ? html`
        <div class="kn-detail-pad">
          <div class="kn-section-head">
            <div class="kn-min-w-0">
              <div class="kn-row-meta">
                <span class="mono">${doc.artifact.id}</span>
                <span class=${`kn-badge ${doc.artifact.format === 'html' ? 'kn-badge--info' : 'kn-badge--ok'}`}>
                  ${doc.artifact.format.toUpperCase()}
                </span>
                <span class="mono tnum">rev ${doc.artifact.revision}</span>
                <span class="tnum">${formatBytes(doc.artifact.bytes)}</span>
              </div>
              <h2 class="kn-heading">${doc.artifact.title}</h2>
              ${doc.artifact.summary && html`
                <${MarkdownContent} class="kn-subcopy" text=${doc.artifact.summary} onNavigate=${props.onNavigate} />
              `}
            </div>
            <div class="kn-actions">
              <button type="button" class="btn-ghost" onClick=${() => void copyText(doc.content, '본문')}>본문 복사</button>
              <button type="button" class="btn-primary" onClick=${() => downloadArtifact(doc)}>다운로드</button>
              <${PopoverMenu}
                align="right"
                triggerLabel="⋯"
                triggerClassName="btn-ghost"
                triggerTestId="artifact-detail-actions"
                popoverTestId="artifact-detail-actions-menu"
                ariaLabel="아티팩트 추가 작업"
                items=${[
                  {
                    id: 'copy-sha',
                    testId: 'artifact-action-copy-sha',
                    label: 'SHA-256 복사',
                    description: doc.artifact.sha256 ? `${doc.artifact.sha256.slice(0, 12)}…` : '없음',
                    disabled: !doc.artifact.sha256,
                    onSelect: () => void copyText(doc.artifact.sha256, 'SHA-256'),
                  },
                  {
                    id: 'metadata',
                    testId: 'artifact-action-metadata',
                    label: '메타데이터',
                    onSelect: () => props.onInspect({
                      title: `Artifact: ${doc.artifact.title}`,
                      subtitle: `${doc.artifact.id} · r${doc.artifact.revision}`,
                      kind: 'artifact',
                      data: doc.artifact,
                    }),
                  },
                ]}
              />
            </div>
          </div>

          <div class="kn-row-meta">
            <${KeeperBadge} id=${doc.artifact.author} size="sm" />
            <span class="mono kn-sha256" data-testid="artifact-sha256" title=${doc.artifact.sha256 || undefined}>
              SHA-256: ${doc.artifact.sha256 || '없음'}
            </span>
            ${doc.artifact.goalId && html`
              <button type="button" class="btn-ghost kn-btn-compact" onClick=${() => props.onNavigate(`/work/goals/${encodeURIComponent(doc.artifact.goalId!)}`)}>
                Goal: ${doc.artifact.goalId} →
              </button>
            `}
            ${doc.artifact.taskId && html`
              <button type="button" class="btn-ghost kn-btn-compact" onClick=${() => props.onNavigate(`/work/tasks/${encodeURIComponent(doc.artifact.taskId!)}`)}>
                Task: ${doc.artifact.taskId} →
              </button>
            `}
            ${doc.revisions.length > 1 && html`
              <select
                class="kn-select"
                value=${String(doc.artifact.revision)}
                onChange=${(e: Event) => setSelectedRevision(Number((e.target as HTMLSelectElement).value))}
                aria-label="리비전 선택"
              >
                ${doc.revisions.map((r) => html`
                  <option key=${r.revision} value=${String(r.revision)}>rev ${r.revision} (${r.sha256.slice(0, 8)})</option>
                `)}
              </select>
            `}
          </div>

          ${doc.artifact.format === 'html'
            ? renderHtmlPreview(doc)
            : html`
                <article class="kn-md-panel">
                  <${MarkdownContent} text=${doc.content} document onNavigate=${props.onNavigate} />
                </article>
              `}
        </div>
      `
    : docLoading
      ? html`<div class="kn-detail-pad"><span class="dtable-absent">아티팩트 본문 불러오는 중…</span></div>`
      : docError
        ? html`<div class="kn-detail-pad"><div class="kn-notice kn-notice--err" role="alert">${docError}</div></div>`
        : null

  return html`
    <${MasterDetail}
      master=${masterPane}
      detail=${detailPane}
      hasSelection=${selectedId !== null}
      selectionKey=${selectedId}
      linkedKey=${props.entityId ?? null}
      masterLabel="아티팩트 목록"
      detailLabel="아티팩트 미리보기"
      emptyDetail=${html`<div class="kn-detail-pad"><span class="dtable-absent">HTML 또는 Markdown 아티팩트를 선택해 미리보세요.</span></div>`}
    />
  `
}
