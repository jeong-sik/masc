/**
 * Quick Embed Picker (`위키·아티팩트 삽입`) for the Librarian Wiki Markdown editor.
 *
 * Inserts canonical Obsidian-style embed syntax (`![[wiki:<slug>]]` or
 * `![[artifact:<id>]]`) with one click so authors never type raw IDs by hand.
 *
 * - Wiki pages come from the editor that owns the page list (`wikiPages`). The
 *   picker asks it to read the list when the wiki tab opens and from the retry
 *   button, so a failed read is shown and can be read again.
 * - Published artifacts lazily read `GET /api/v1/published-artifacts` via the shared
 *   `PUBLISHED_ARTIFACTS_LIST_KEY` `resourceCache` entry, gated strictly by
 *   `canUseSingleUserTokenAdmin(session)` (zero speculative 401/403 calls). The
 *   list renders from that entry's state, so every outcome of a read is shown.
 */

import { html } from 'htm/preact'
import { useEffect, useMemo, useState } from 'preact/hooks'
import {
  authSession,
  canUseSingleUserTokenAdmin,
  sessionEpoch,
} from '../../core/auth'
import { resourceCache, type Observed } from '../../core/resource-cache'
import { PopoverMenu } from '../../components/primitives'
import {
  PUBLISHED_ARTIFACTS_LIST_KEY,
  readPublishedArtifactsList,
  type ArtifactListBundle,
} from './artifacts-tab'
import type { PublishedArtifactItem, WikiPageSummary } from './types'

type EmbedPickerTab = 'wiki' | 'artifact'

/** The wiki page list the picker offers, as its owner last read it. */
export type WikiEmbedPages =
  | { readonly kind: 'loading' }
  | { readonly kind: 'ready'; readonly pages: readonly WikiPageSummary[] }
  | { readonly kind: 'failed'; readonly message: string }

const MAX_PICKER_RESULTS = 40

const NO_ARTIFACT_LIST_MESSAGE = '발행된 아티팩트 목록을 받지 못했습니다.'

// Shared empty lists keep the memoized filters stable while a list is not ready.
const NO_PAGES: readonly WikiPageSummary[] = []
const NO_ARTIFACTS: readonly PublishedArtifactItem[] = []

export interface WikiEmbedPickerProps {
  readonly wikiPages: WikiEmbedPages
  /** Reads the wiki page list: `mount` when the wiki tab opens, `manual` from the retry button. */
  readonly onLoadWikiPages: (reason: 'mount' | 'manual') => void
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

function artifactsOf(obs: Observed<ArtifactListBundle> | null): readonly PublishedArtifactItem[] {
  return obs !== null && obs.kind === 'value' ? obs.data.artifacts : NO_ARTIFACTS
}

/** The message for a read that ended without a list, or null when there is a list or a read is running. */
function artifactListProblem(obs: Observed<ArtifactListBundle>): string | null {
  switch (obs.kind) {
    case 'loading':
    case 'value':
      return null
    case 'failed':
      return obs.error.message
    case 'absent':
    case 'unreported':
      return obs.reason ?? NO_ARTIFACT_LIST_MESSAGE
  }
}

function RetryNotice({ message, testId, onRetry }: {
  readonly message: string
  readonly testId: string
  readonly onRetry: () => void
}) {
  return html`
    <div class="kn-notice kn-notice--err" role="alert" data-testid=${testId}>
      <span>${message}</span>
      <button
        type="button"
        class="btn-ghost kn-btn-compact"
        data-testid=${`${testId}-retry`}
        onClick=${onRetry}
      >
        다시 불러오기
      </button>
    </div>
  `
}

export function WikiEmbedPicker({
  wikiPages,
  onLoadWikiPages,
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

  // Read only while the picker is open, so a closed picker creates no cache entry.
  const artifactsObs = open && canListArtifacts
    ? resourceCache.observe<ArtifactListBundle>(PUBLISHED_ARTIFACTS_LIST_KEY).value
    : null
  const artifacts = artifactsOf(artifactsObs)

  useEffect(() => {
    if (disabled) setOpen(false)
  }, [disabled])

  useEffect(() => {
    if (!open || tab !== 'wiki') return
    onLoadWikiPages('mount')
  }, [open, tab, onLoadWikiPages, epoch])

  useEffect(() => {
    if (!open || tab !== 'artifact' || !canListArtifacts) return
    void readPublishedArtifactsList('mount')
  }, [open, tab, canListArtifacts, epoch])

  const pages = wikiPages.kind === 'ready' ? wikiPages.pages : NO_PAGES

  const matchedPages = useMemo(() => {
    const q = query.trim().toLowerCase()
    return pages.filter((page) => {
      if (!q) return true
      return (
        page.title.toLowerCase().includes(q)
        || page.slug.toLowerCase().includes(q)
        || page.tags.some((t) => t.toLowerCase().includes(q))
      )
    })
  }, [pages, query])

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

  const renderWikiPages = () => {
    switch (wikiPages.kind) {
      case 'loading':
        return html`<span class="dtable-absent">위키 목록 불러오는 중…</span>`
      case 'failed':
        return html`
          <${RetryNotice}
            message=${wikiPages.message}
            testId="wiki-embed-picker-wiki-error"
            onRetry=${() => onLoadWikiPages('manual')}
          />
        `
      case 'ready':
        break
    }
    if (filteredPages.length === 0) {
      return html`<div class="kn-embed-picker-list"><span class="dtable-absent">일치하는 위키 페이지가 없습니다.</span></div>`
    }
    return html`
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
  }

  const renderArtifacts = () => {
    if (!isSingleUser) {
      return html`
        <div class="kn-notice kn-notice--info" role="status">
          발행된 아티팩트 목록 조회는 싱글유저 로컬 세션에서 지원됩니다.
        </div>
      `
    }
    if (!canListArtifacts || artifactsObs === null) {
      return html`
        <div class="kn-notice kn-notice--info" role="status">
          아티팩트 목록 조회는 토큰 기반 관리자 권한이 필요합니다.
        </div>
      `
    }
    const problem = artifactListProblem(artifactsObs)
    if (problem !== null) {
      return html`
        <${RetryNotice}
          message=${problem}
          testId="wiki-embed-picker-artifact-error"
          onRetry=${() => { void readPublishedArtifactsList('manual') }}
        />
      `
    }
    if (artifactsObs.kind === 'loading') {
      return html`<span class="dtable-absent">아티팩트 목록 불러오는 중…</span>`
    }
    if (filteredArtifacts.length === 0) {
      return html`<div class="kn-embed-picker-list"><span class="dtable-absent">일치하는 아티팩트가 없습니다.</span></div>`
    }
    return html`
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
            위키
            ${wikiPages.kind === 'ready' && html`
              <span class="kn-chip-count">${wikiPages.pages.length}</span>
            `}
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
            ${artifacts.length > 0 && html`
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

        ${tab === 'wiki' ? renderWikiPages() : renderArtifacts()}
      `}
    <//>
  `
}
