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
import { apiGet } from '../../core/transport'
import { ok } from '../../lib/result'
import { PopoverMenu } from '../../components/primitives'
import {
  asNonEmptyString,
  decodePublishedArtifactItem,
  isRecord,
  type PublishedArtifactItem,
  type WikiPageSummary,
} from './types'

type EmbedPickerTab = 'wiki' | 'artifact'

interface ArtifactListBundle {
  readonly artifacts: readonly PublishedArtifactItem[]
  readonly diagnostics: readonly { readonly id: string; readonly error: string }[]
}

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
        async (signal) => {
          const res = await apiGet<unknown>('/api/v1/published-artifacts', { signal })
          if (!res.ok) return res
          const list: PublishedArtifactItem[] = []
          const diagnostics: { id: string; error: string }[] = []
          if (isRecord(res.value)) {
            if (Array.isArray(res.value.artifacts)) {
              for (const row of res.value.artifacts) {
                const dec = decodePublishedArtifactItem(row)
                if (dec) list.push(dec)
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
          return ok({ artifacts: list, diagnostics })
        },
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

  const filteredPages = useMemo(() => {
    const q = query.trim().toLowerCase()
    const list = wikiPages.filter((page) => {
      if (!q) return true
      return (
        page.title.toLowerCase().includes(q)
        || page.slug.toLowerCase().includes(q)
        || page.tags.some((t) => t.toLowerCase().includes(q))
      )
    })
    return list.slice(0, 40)
  }, [wikiPages, query])

  const filteredArtifacts = useMemo(() => {
    const q = query.trim().toLowerCase()
    const list = artifacts.filter((item) => {
      if (!q) return true
      return (
        item.title.toLowerCase().includes(q)
        || item.id.toLowerCase().includes(q)
        || item.summary.toLowerCase().includes(q)
      )
    })
    return list.slice(0, 40)
  }, [artifacts, query])

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
      align="left"
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
          ? html`
              <div class="kn-embed-picker-list" role="list" aria-label="삽입할 위키 페이지 목록">
                ${filteredPages.length === 0
                  ? html`<span class="dtable-absent">일치하는 위키 페이지가 없습니다.</span>`
                  : filteredPages.map((page) => html`
                      <button
                        key=${page.slug}
                        type="button"
                        role="listitem"
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
                    `)}
              </div>
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
                  : html`
                      <div class="kn-embed-picker-list" role="list" aria-label="삽입할 아티팩트 목록">
                        ${filteredArtifacts.length === 0
                          ? html`<span class="dtable-absent">일치하는 아티팩트가 없습니다.</span>`
                          : filteredArtifacts.map((item) => html`
                              <button
                                key=${item.id}
                                type="button"
                                role="listitem"
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
                            `)}
                      </div>
                    `}
      `}
    <//>
  `
}
