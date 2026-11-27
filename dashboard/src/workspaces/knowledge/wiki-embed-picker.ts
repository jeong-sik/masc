/**
 * Quick Embed Picker (`위키·아티팩트 삽입`) for the Librarian Wiki Markdown editor.
 *
 * Inserts canonical Obsidian-style embed syntax (`![[wiki:<slug>]]` or
 * `![[artifact:<id>]]`) with one click so authors never type raw IDs by hand.
 *
 * - Wiki pages reuse the already-loaded `wikiIndex.pages` prop (zero extra request).
 * - Published artifacts lazily read `GET /api/v1/published-artifacts` via the shared
 *   `kn:artifacts:list` `resourceCache` entry, gated strictly by
 *   `canUseSingleUserTokenAdmin(session)` (zero speculative 401/403 calls).
 */

import { html } from 'htm/preact'
import { useEffect, useMemo, useRef, useState } from 'preact/hooks'
import {
  authSession,
  canUseSingleUserTokenAdmin,
  currentSessionEpoch,
  isEpochCurrent,
  sessionEpoch,
} from '../../core/auth'
import { resourceCache } from '../../core/resource-cache'
import { PopoverMenu } from '../../components/primitives'
import { fetchPublishedArtifactsList, type ArtifactListBundle } from './artifacts-tab'
import type { PublishedArtifactItem, WikiPageSummary } from './types'

type EmbedPickerTab = 'wiki' | 'artifact'

const MAX_PICKER_RESULTS = 40

export interface WikiEmbedPickerProps {
  readonly wikiPages: readonly WikiPageSummary[]
  readonly currentSlug?: string | null
  readonly disabled?: boolean
  readonly onInsertEmbed: (markdown: string) => void
}

export function formatWikiEmbed(slug: string): string {
  return `![[wiki:${slug.trim()}]]`
}

export function formatArtifactEmbed(id: string): string {
  return `![[artifact:${id.trim()}]]`
}

export function WikiEmbedPicker({
  wikiPages,
  currentSlug,
  disabled = false,
  onInsertEmbed,
}: WikiEmbedPickerProps) {
  const session = authSession.value
  const epoch = sessionEpoch.value
  const isSingleUser = session.kind === 'single_user_local'
  const canListArtifacts = canUseSingleUserTokenAdmin(session)

  const [open, setOpen] = useState(false)
  const [tab, setTab] = useState<EmbedPickerTab>('wiki')
  const [query, setQuery] = useState('')
  const [artifacts, setArtifacts] = useState<readonly PublishedArtifactItem[]>([])
  const [artifactsLoading, setArtifactsLoading] = useState(false)
  const [artifactsError, setArtifactsError] = useState<string | null>(null)
  const mountedRef = useRef(true)

  useEffect(() => {
    mountedRef.current = true
    return () => {
      mountedRef.current = false
    }
  }, [])

  useEffect(() => {
    if (disabled) setOpen(false)
  }, [disabled])

  // Clear cached artifact selection state whenever workspace/account epoch changes.
  useEffect(() => {
    setArtifacts([])
    setArtifactsError(null)
    setArtifactsLoading(false)
  }, [epoch])

  useEffect(() => {
    if (!open || tab !== 'artifact' || !canListArtifacts) return
    let cancelled = false
    const startEpoch = currentSessionEpoch()
    setArtifactsLoading(true)
    setArtifactsError(null)

    void resourceCache
      .fetch<ArtifactListBundle>(
        'kn:artifacts:list',
        fetchPublishedArtifactsList,
        { ttlMs: 15_000, topics: ['artifacts'], reason: 'mount' },
      )
      .then((obs) => {
        if (cancelled || !mountedRef.current || !isEpochCurrent(startEpoch)) return
        setArtifactsLoading(false)
        if (obs.kind === 'value') {
          setArtifacts(obs.data.artifacts)
        } else if (obs.kind === 'failed') {
          setArtifactsError(obs.error.message)
        }
      })

    return () => {
      cancelled = true
    }
  }, [open, tab, canListArtifacts, epoch])

  const matchedPages = useMemo(() => {
    const q = query.trim().toLowerCase()
    return wikiPages.filter((page) => {
      if (!q) return true
      return (
        page.title.toLowerCase().includes(q)
        || page.slug.toLowerCase().includes(q)
        || page.tags.some((t) => t.toLowerCase().includes(q))
      )
    })
  }, [wikiPages, query])

  const filteredPages = useMemo(
    () => matchedPages.slice(0, MAX_PICKER_RESULTS),
    [matchedPages],
  )
  const hiddenPagesCount = Math.max(0, matchedPages.length - filteredPages.length)

  const matchedArtifacts = useMemo(() => {
    const q = query.trim().toLowerCase()
    return artifacts.filter((item) => {
      if (!q) return true
      return (
        item.title.toLowerCase().includes(q)
        || item.id.toLowerCase().includes(q)
        || item.summary.toLowerCase().includes(q)
      )
    })
  }, [artifacts, query])

  const filteredArtifacts = useMemo(
    () => matchedArtifacts.slice(0, MAX_PICKER_RESULTS),
    [matchedArtifacts],
  )
  const hiddenArtifactsCount = Math.max(0, matchedArtifacts.length - filteredArtifacts.length)

  const selectEmbed = (snippet: string) => {
    setOpen(false)
    setQuery('')
    onInsertEmbed(snippet)
  }

  if (disabled) {
    return html`
      <button
        type="button"
        class="btn-ghost kn-btn-compact"
        data-testid="wiki-embed-picker-trigger"
        disabled
      >
        위키·아티팩트 삽입 ▾
      </button>
    `
  }

  return html`
    <${PopoverMenu}
      align="right"
      role="dialog"
      open=${open}
      onOpenChange=${(next: boolean) => {
        setOpen(next)
        if (!next) setQuery('')
      }}
      closeOnSelect=${false}
      triggerLabel="위키·아티팩트 삽입 ▾"
      triggerClassName="btn-ghost kn-btn-compact"
      triggerTestId="wiki-embed-picker-trigger"
      popoverTestId="wiki-embed-picker-popover"
      popoverClassName="kn-embed-picker-popover"
      ariaLabel="위키·아티팩트 삽입"
    >
      ${() => html`
        <div class="kn-chips" role="tablist" aria-label="삽입 대상 종류">
          <button
            type="button"
            role="tab"
            class="kn-chip"
            aria-selected=${tab === 'wiki' ? 'true' : 'false'}
            data-testid="wiki-embed-tab-wiki"
            onClick=${() => setTab('wiki')}
          >
            위키 <span class="kn-chip-count">${wikiPages.length}</span>
          </button>
          <button
            type="button"
            role="tab"
            class="kn-chip"
            aria-selected=${tab === 'artifact' ? 'true' : 'false'}
            data-testid="wiki-embed-tab-artifact"
            onClick=${() => setTab('artifact')}
          >
            아티팩트
            ${canListArtifacts && artifacts.length > 0 && html`
              <span class="kn-chip-count">${artifacts.length}</span>
            `}
          </button>
        </div>

        <input
          type="search"
          class="kn-input"
          placeholder=${tab === 'wiki' ? '위키 제목, slug, 태그 검색…' : '아티팩트 제목, ID 검색…'}
          value=${query}
          onInput=${(e: Event) => setQuery((e.target as HTMLInputElement).value)}
          aria-label=${tab === 'wiki' ? '위키 임베드 검색' : '아티팩트 임베드 검색'}
          data-testid="wiki-embed-picker-search"
        />

        ${tab === 'wiki'
          ? filteredPages.length === 0
            ? html`<div class="kn-embed-picker-list"><span class="dtable-absent">일치하는 위키 페이지가 없습니다.</span></div>`
            : html`
                <div class="kn-embed-picker-list" role="list" aria-label="삽입할 위키 페이지 목록">
                  ${filteredPages.map((page) => html`
                    <div key=${page.slug} role="listitem">
                      <button
                        type="button"
                        class="kn-embed-picker-item"
                        data-testid=${`wiki-embed-option-wiki-${page.slug}`}
                        onClick=${() => selectEmbed(formatWikiEmbed(page.slug))}
                      >
                        <span class="kn-embed-picker-title">
                          ${page.title}
                          ${currentSlug === page.slug ? ' (현재 페이지)' : ''}
                        </span>
                        <span class="kn-embed-picker-meta">
                          <span class="mono">${page.slug}</span>
                          <span>rev ${page.revision}</span>
                        </span>
                      </button>
                    </div>
                  `)}
                </div>
                ${hiddenPagesCount > 0 && html`
                  <div class="kn-embed-picker-overflow" data-testid="wiki-embed-picker-overflow">
                    +${hiddenPagesCount}건 더 있음 — 검색어로 좁혀주세요
                  </div>
                `}
              `
          : !isSingleUser
            ? html`
                <div class="kn-notice kn-notice--info" role="status">
                  발행된 아티팩트 목록 조회는 싱글유저 로컬 세션에서 지원됩니다.
                </div>
              `
            : !canListArtifacts
              ? html`
                  <div class="kn-notice kn-notice--info" role="status">
                    아티팩트 목록 조회는 토큰 기반 관리자 권한이 필요합니다.
                  </div>
                `
              : artifactsError
                ? html`<div class="kn-notice kn-notice--err" role="alert">${artifactsError}</div>`
                : artifactsLoading && artifacts.length === 0
                  ? html`<span class="dtable-absent">아티팩트 목록 불러오는 중…</span>`
                  : filteredArtifacts.length === 0
                    ? html`<div class="kn-embed-picker-list"><span class="dtable-absent">일치하는 아티팩트가 없습니다.</span></div>`
                    : html`
                        <div class="kn-embed-picker-list" role="list" aria-label="삽입할 아티팩트 목록">
                          ${filteredArtifacts.map((item) => html`
                            <div key=${item.id} role="listitem">
                              <button
                                type="button"
                                class="kn-embed-picker-item"
                                data-testid=${`wiki-embed-option-artifact-${item.id}`}
                                onClick=${() => selectEmbed(formatArtifactEmbed(item.id))}
                              >
                                <span class="kn-embed-picker-title">${item.title}</span>
                                <span class="kn-embed-picker-meta">
                                  <span class="mono">${item.id}</span>
                                  <span class="kn-badge">${item.format.toUpperCase()}</span>
                                </span>
                              </button>
                            </div>
                          `)}
                        </div>
                        ${hiddenArtifactsCount > 0 && html`
                          <div class="kn-embed-picker-overflow" data-testid="wiki-embed-picker-overflow">
                            +${hiddenArtifactsCount}건 더 있음 — 검색어로 좁혀주세요
                          </div>
                        `}
                      `}
      `}
    <//>
  `
}
