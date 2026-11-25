/**
 * `3 Knowledge > Lean Artifacts` Tab (`artifacts-tab.ts`)
 *
 * - `MasterDetail` + `VirtualList`: Published HTML / Markdown artifact list (`GET /api/v1/published-artifacts`).
 * - Safe sandboxed HTML iframe preview (`sandbox=""`) OR DOMPurify-sanitized Markdown render.
 * - Copy content, Copy SHA-256, Download `.html`/`.md`, revision switching — ZERO Office/HWP/PDF/Yjs bloat!
 */

import { html } from 'htm/preact'
import { MarkdownContent } from '../../components/common/markdown-renderer'
import { useCallback, useEffect, useMemo, useRef, useState } from 'preact/hooks'
import { markViewSnapshot } from '../../core/observer'
import { resourceCache } from '../../core/resource-cache'
import { apiGet } from '../../core/transport'
import { ok } from '../../lib/result'
import { KeeperBadge } from '../../components/keeper-badge'
import { MasterDetail, VirtualList } from '../../components/primitives'
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

interface ArtifactListBundle {
  readonly artifacts: readonly PublishedArtifactItem[]
  readonly diagnostics: readonly { readonly id: string; readonly error: string }[]
}

export function ArtifactsTab(props: WorkspaceViewProps) {
  const [bundle, setBundle] = useState<ArtifactListBundle>({ artifacts: [], diagnostics: [] })
  const [loading, setLoading] = useState(true)
  const [loadError, setLoadError] = useState<string | null>(null)
  const [formatFilter, setFormatFilter] = useState<'all' | 'html' | 'markdown'>('all')
  const [query, setQuery] = useState('')

  const [selectedId, setSelectedId] = useState<string | null>(props.entityId ?? null)
  const [selectedRevision, setSelectedRevision] = useState<number | null>(null)
  const [doc, setDoc] = useState<ArtifactDocumentData | null>(null)
  const [docLoading, setDocLoading] = useState(false)
  const [docError, setDocError] = useState<string | null>(null)
  const [copyNotice, setCopyNotice] = useState<string | null>(null)
  const docAbortRef = useRef<AbortController | null>(null)

  const loadList = useCallback(async (reason: 'mount' | 'manual' = 'mount') => {
    setLoading(true)
    setLoadError(null)
    const obs = await resourceCache.fetch<ArtifactListBundle>(
      'kn:artifacts:list',
      async (signal) => {
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
        return ok({ artifacts, diagnostics })
      },
      { ttlMs: 15_000, topics: ['artifacts'], reason },
    )
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
  }, [loadList])

  const loadDocument = useCallback(async (id: string, revision: number | null, signal?: AbortSignal) => {
    setDocLoading(true)
    setDocError(null)
    const revQuery = revision !== null ? `?revision=${revision}` : ''
    const res = await apiGet<unknown>(`/api/v1/published-artifacts/${encodeURIComponent(id)}${revQuery}`, { signal })
    if (signal?.aborted) return
    setDocLoading(false)
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
    setCopyNotice(null)
    setDoc(null)
    if (!selectedId) {
      setDocLoading(false)
      return
    }
    const ctrl = new AbortController()
    docAbortRef.current = ctrl
    void loadDocument(selectedId, selectedRevision, ctrl.signal)
    return () => {
      ctrl.abort()
    }
  }, [selectedId, selectedRevision, loadDocument])

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
    try {
      if (typeof navigator !== 'undefined' && navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(text)
      }
      setCopyNotice(`${label} 복사됨`)
      setTimeout(() => setCopyNotice(null), 2000)
    } catch {
      setCopyNotice('클립보드 복사를 지원하지 않는 환경입니다.')
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

  const masterPane = html`
    <div class="kn-pane-col">
      <div class="kn-pane-head">
        <h2 class="kn-pane-title">Artifacts <span class="kn-chip-count">(${filtered.length})</span></h2>
        <button type="button" class="btn-ghost" onClick=${() => void loadList('manual')}>새로고침</button>
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
                <${MarkdownContent} class="kn-subcopy" text=${doc.artifact.summary} />
              `}
            </div>
            <div class="kn-actions">
              <button type="button" class="btn-ghost" onClick=${() => void copyText(doc.content, '본문')}>본문 복사</button>
              <button type="button" class="btn-ghost" onClick=${() => void copyText(doc.artifact.sha256, 'SHA-256')}>SHA-256 복사</button>
              <button type="button" class="btn-primary" onClick=${() => downloadArtifact(doc)}>다운로드</button>
              <button
                type="button"
                class="btn-ghost"
                onClick=${() => props.onInspect({
                  title: `Artifact: ${doc.artifact.title}`,
                  subtitle: `${doc.artifact.id} · r${doc.artifact.revision}`,
                  kind: 'artifact',
                  data: doc.artifact,
                })}
              >
                메타데이터
              </button>
            </div>
          </div>

          ${copyNotice && html`<div class="kn-notice kn-notice--ok" role="status">${copyNotice}</div>`}

          <div class="kn-row-meta">
            <${KeeperBadge} id=${doc.artifact.author} size="sm" />
            <span class="mono" title=${doc.artifact.sha256}>
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
            ? html`
                <iframe
                  class="kn-artifact-frame"
                  sandbox=""
                  srcDoc=${doc.content}
                  title=${`Sandboxed HTML Artifact: ${doc.artifact.title}`}
                />
              `
            : html`
                <article class="kn-md-panel">
                  <${MarkdownContent} text=${doc.content} document />
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
      hasSelection=${doc !== null || docLoading || docError !== null}
      selectionKey=${selectedId}
      masterLabel="아티팩트 목록"
      detailLabel="아티팩트 미리보기"
      emptyDetail=${html`<div class="kn-detail-pad"><span class="dtable-absent">HTML 또는 Markdown 아티팩트를 선택해 미리보세요.</span></div>`}
    />
  `
}
