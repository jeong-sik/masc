// Published Artifacts HTML / Markdown viewer with strict sandbox="" HTML hydration.

import { html } from 'htm/preact'
import { useEffect, useState } from 'preact/hooks'
import {
  fetchPublishedArtifact,
  fetchPublishedArtifacts,
  type ArtifactDocument,
  type PublishedArtifact,
} from '../../api/published-artifacts'
import { isEpochCurrent, sessionEpoch } from '../../core/auth'
import { WORKSPACE_MEDIA_PREFIX } from '../../lib/keeper-media'
import { hydrateSandboxedHtmlMedia } from '../../lib/workspace-media-cache'
import { MarkdownContent } from '../common/markdown-renderer'
import { LoadingState, EmptyState } from '../common/feedback-state'
import { navigate, route } from '../../router'

export function ArtifactsSurface() {
  const epoch = sessionEpoch.value
  const [artifacts, setArtifacts] = useState<readonly PublishedArtifact[]>([])
  const [listLoading, setListLoading] = useState(true)
  const [listError, setListError] = useState<string | null>(null)
  const [doc, setDoc] = useState<ArtifactDocument | null>(null)
  const [docLoading, setDocLoading] = useState(false)
  const [docError, setDocError] = useState<string | null>(null)
  const [hydratedHtml, setHydratedHtml] = useState<{ readonly key: string; readonly html: string } | null>(null)

  const selectedId = route.value.params.artifact?.trim() || ''
  const selectedRevision = route.value.params.revision?.trim() || undefined

  useEffect(() => {
    const controller = new AbortController()
    setListLoading(true)
    setListError(null)
    void fetchPublishedArtifacts(controller.signal)
      .then(result => {
        if (controller.signal.aborted || !isEpochCurrent(epoch)) return
        setArtifacts(result.artifacts)
        setListLoading(false)
      })
      .catch(error => {
        if (controller.signal.aborted || !isEpochCurrent(epoch)) return
        setListError(error instanceof Error ? error.message : String(error))
        setListLoading(false)
      })
    return () => controller.abort()
  }, [epoch])

  const activeId = selectedId || artifacts[0]?.id || ''

  useEffect(() => {
    setHydratedHtml(null)
    if (!activeId) {
      setDoc(null)
      setDocError(null)
      return
    }
    const controller = new AbortController()
    setDocLoading(true)
    setDocError(null)
    void fetchPublishedArtifact(activeId, selectedRevision, controller.signal)
      .then(loaded => {
        if (controller.signal.aborted || !isEpochCurrent(epoch)) return
        setDoc(loaded)
        setDocLoading(false)
      })
      .catch(error => {
        if (controller.signal.aborted || !isEpochCurrent(epoch)) return
        setDoc(null)
        setDocError(error instanceof Error ? error.message : String(error))
        setDocLoading(false)
      })
    return () => controller.abort()
  }, [activeId, selectedRevision, epoch])

  const htmlKey = doc && doc.artifact.format === 'html'
    ? `${epoch}:${doc.artifact.id}:${doc.artifact.revision}:${doc.content.length}`
    : null
  const needsHydration = doc !== null
    && doc.artifact.format === 'html'
    && doc.content.includes(WORKSPACE_MEDIA_PREFIX)

  useEffect(() => {
    if (!doc || !htmlKey || !needsHydration) {
      setHydratedHtml(null)
      return undefined
    }
    const controller = new AbortController()
    void hydrateSandboxedHtmlMedia(doc.content, { epoch, signal: controller.signal }).then((res) => {
      if (controller.signal.aborted || !isEpochCurrent(epoch) || !res.ok) return
      setHydratedHtml({
        key: htmlKey,
        html: res.value.html,
      })
    })
    return () => controller.abort()
  }, [doc, epoch, htmlKey, needsHydration])

  if (listLoading) {
    return html`<${LoadingState}>아티팩트 목록 로딩 중...<//>`
  }

  if (listError) {
    return html`<${EmptyState} message=${`아티팩트 목록 오류: ${listError}`} />`
  }

  if (artifacts.length === 0) {
    return html`<${EmptyState} message="게시된 아티팩트가 없습니다." />`
  }

  const activeHydrated = htmlKey && hydratedHtml?.key === htmlKey ? hydratedHtml.html : null

  return html`
    <div class="artifacts-viewer grid gap-4 md:grid-cols-[minmax(220px,320px)_minmax(0,1fr)]" data-testid="artifacts-surface">
      <aside class="flex flex-col gap-1.5 min-w-0">
        <div class="text-xs font-semibold uppercase tracking-wide text-[var(--color-fg-muted)]">
          게시된 아티팩트 (${artifacts.length})
        </div>
        ${artifacts.map(item => {
          const active = item.id === activeId
          return html`
            <button
              key=${item.id}
              type="button"
              class=${`text-left rounded-[var(--r-1)] border px-3 py-2 text-xs transition-colors ${
                active
                  ? 'border-[var(--color-border-strong)] bg-[var(--color-bg-elevated)] text-[var(--color-fg-primary)]'
                  : 'border-[var(--color-border-default)] bg-[var(--color-bg-surface)] text-[var(--color-fg-secondary)] hover:bg-[var(--color-bg-hover)]'
              }`}
              onClick=${() => navigate('workspace', { section: 'artifacts', artifact: item.id })}
            >
              <div class="font-medium truncate">${item.title || item.id}</div>
              <div class="mt-0.5 flex items-center gap-2 text-3xs text-[var(--color-fg-muted)] font-mono tabular-nums">
                <span>${item.format}</span>
                <span>r${item.revision}</span>
                <span>${item.author}</span>
              </div>
            </button>
          `
        })}
      </aside>
      <section class="min-w-0 rounded-[var(--r-2)] border border-[var(--color-border-default)] bg-[var(--color-bg-surface)] p-4">
        ${docLoading
          ? html`<${LoadingState}>문서 로딩 중...<//>`
          : docError
            ? html`<${EmptyState} message=${`문서 로드 실패: ${docError}`} compact />`
            : doc
              ? html`
                  <header class="mb-3 border-b border-[var(--color-border-default)] pb-2">
                    <h2 class="text-base font-semibold text-[var(--color-fg-primary)]">${doc.artifact.title}</h2>
                    <div class="mt-1 flex flex-wrap items-center gap-2 text-xs text-[var(--color-fg-muted)] font-mono tabular-nums">
                      <span>${doc.artifact.id}</span>
                      <span>rev ${doc.artifact.revision}</span>
                      <span>${doc.artifact.format}</span>
                      <span>by ${doc.artifact.author}</span>
                    </div>
                  </header>
                  ${doc.artifact.format === 'html'
                    ? (needsHydration && activeHydrated === null
                        ? html`<${LoadingState}>아티팩트 이미지 불러오는 중...<//>`
                        : html`
                            <iframe
                              class="w-full min-h-[460px] rounded-[var(--r-1)] border border-[var(--color-border-default)] bg-[var(--color-bg-base)]"
                              sandbox=""
                              srcDoc=${activeHydrated ?? doc.content}
                              title=${`Sandboxed HTML Artifact: ${doc.artifact.title}`}
                            />
                          `)
                    : html`<${MarkdownContent} text=${doc.content} document />`}
                `
              : html`<${EmptyState} message="아티팩트를 선택하세요." compact />`}
      </section>
    </div>
  `
}
