import { post } from './core'
import { isRecord, asString } from '../components/common/normalize'

export type LinkPreviewKind = 'link' | 'image'

export interface LinkPreview {
  url: string
  kind: LinkPreviewKind
  canonical_url?: string | null
  title?: string | null
  description?: string | null
  site_name?: string | null
  image_url?: string | null
  favicon_url?: string | null
  content_type?: string | null
  fetched_at?: string | null
  cache_state?: string | null
}

interface LinkPreviewResponse {
  previews?: Record<string, unknown>
  errors?: Record<string, unknown>
}

interface CacheEntry {
  preview: LinkPreview | null
  expiresAt: number
}

const LOCAL_PREVIEW_TTL_MS = 15 * 60 * 1000
const LOCAL_ERROR_TTL_MS = 5 * 60 * 1000
const previewCache = new Map<string, CacheEntry>()

function normalizeLinkPreview(raw: unknown): LinkPreview | null {
  if (!isRecord(raw)) return null
  const url = asString(raw.url)
  const kind = asString(raw.kind)
  if (!url || (kind !== 'link' && kind !== 'image')) return null
  return {
    url,
    kind,
    canonical_url: asString(raw.canonical_url) ?? null,
    title: asString(raw.title) ?? null,
    description: asString(raw.description) ?? null,
    site_name: asString(raw.site_name) ?? null,
    image_url: asString(raw.image_url) ?? null,
    favicon_url: asString(raw.favicon_url) ?? null,
    content_type: asString(raw.content_type) ?? null,
    fetched_at: asString(raw.fetched_at) ?? null,
    cache_state: asString(raw.cache_state) ?? null,
  }
}

function shouldUseCached(entry: CacheEntry | undefined): entry is CacheEntry {
  return Boolean(entry && entry.expiresAt > Date.now())
}

export async function fetchLinkPreviews(urls: string[]): Promise<Record<string, LinkPreview>> {
  const uniqueUrls = [...new Set(urls.map(url => url.trim()).filter(Boolean))].slice(0, 8)
  if (uniqueUrls.length === 0) return {}

  const result: Record<string, LinkPreview> = {}
  const missing: string[] = []

  for (const url of uniqueUrls) {
    const cached = previewCache.get(url)
    if (shouldUseCached(cached)) {
      if (cached.preview) result[url] = cached.preview
      continue
    }
    missing.push(url)
  }

  if (missing.length === 0) return result

  const raw = await post<LinkPreviewResponse>('/api/v1/dashboard/link-previews', { urls: missing })
  const previews = isRecord(raw.previews) ? raw.previews : {}
  const errors = isRecord(raw.errors) ? raw.errors : {}

  for (const url of missing) {
    const preview = normalizeLinkPreview(previews[url])
    if (preview) {
      previewCache.set(url, { preview, expiresAt: Date.now() + LOCAL_PREVIEW_TTL_MS })
      result[url] = preview
      continue
    }

    if (errors[url] !== undefined) {
      previewCache.set(url, { preview: null, expiresAt: Date.now() + LOCAL_ERROR_TTL_MS })
    }
  }

  return result
}
